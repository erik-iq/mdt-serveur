#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerUrl,
    [Parameter(Mandatory)][Guid]$DeploymentId,
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$ImagePath,
    [string]$LocalConfirmation,
    [switch]$StartFromWizard,
    [switch]$AllowHttpForLab
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$headers = @{ Authorization = "Bearer $Token" }
$ServerUrl = $ServerUrl.TrimEnd('/')
$endpoint = "$ServerUrl/api/agent/$DeploymentId"
$lastProgress = 0
$started = $false
$mutex = $null
$ownsMutex = $false
. (Join-Path $PSScriptRoot 'Unattend.ps1')
. (Join-Path $PSScriptRoot 'Partitions.ps1')

function Send-Event([string]$Status, [int]$Percent, [string]$Message) {
    $body = @{status=$Status; progress=$Percent; message=$Message} | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$endpoint/events" -Method Post -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    $script:lastProgress = $Percent
    Write-Information -MessageData ("ATELIER|$Percent|$Message") -InformationAction Continue
}
function Run-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable a retourné le code $LASTEXITCODE" }
}
function Assert-Active {
    $current = Invoke-RestMethod -Uri "$endpoint/plan" -Headers $headers
    if ($current.status -ne 'running') { throw 'Le déploiement n''est plus actif.' }
}

try {
    if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')) { throw 'Cet agent fonctionne uniquement dans WinPE.' }
    $uri = [Uri]$ServerUrl
    if ($uri.Scheme -ne 'https' -and -not ($AllowHttpForLab -and $uri.Scheme -eq 'http')) { throw 'HTTPS requis. HTTP est réservé au laboratoire avec -AllowHttpForLab.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $mutex = New-Object Threading.Mutex($false, 'Global\AtelierPXE-Deployment')
    $ownsMutex = $mutex.WaitOne(0)
    if (-not $ownsMutex) { throw 'Un autre agent est déjà actif sur ce poste.' }
    $plan = Invoke-RestMethod -Uri "$endpoint/plan" -Headers $headers
    if ($plan.status -ne 'queued') { throw 'Ce déploiement a déjà été commencé ; créez une nouvelle autorisation après diagnostic.' }
    $macs = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.MACAddress } | ForEach-Object { $_.MACAddress.Replace('-', ':').ToUpperInvariant() })
    if ($plan.mac -notin $macs) { throw 'L''adresse MAC du poste ne correspond pas à la machine autorisée.' }
    Run-Checked 'wpeutil.exe' @('UpdateBootInfo')
    $firmware = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType).PEFirmwareType
    if ($firmware -ne 2) { throw 'Le déploiement nécessite un démarrage UEFI (BIOS legacy non pris en charge).' }
    $disk = Get-Disk -Number $plan.disk_number
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.IsOffline -or $disk.IsReadOnly -or $disk.BusType -eq 'USB') { throw 'Disque système, USB, hors ligne ou en lecture seule : opération refusée.' }
    if ($disk.Size -lt 64GB) { throw 'Un disque de 64 Go minimum est requis.' }
    foreach ($letter in @('S','W','R')) {
        if (Test-Path "${letter}:\") { throw "La lettre $letter est occupée. Libérez-la avant le déploiement." }
    }
    $source = Get-Item -LiteralPath $ImagePath
    if ($source.PSIsContainer -or $source.Length -ne $plan.image_size -or $source.Extension -ne '.wim') { throw 'La source doit être le fichier WIM enregistré dans la console.' }
    if ($source.FullName -notmatch '^\\\\') {
        $sourceDisk = Get-Partition -DriveLetter $source.FullName.Substring(0,1) | Get-Disk
        if ($sourceDisk.Number -eq $disk.Number) { throw 'L''image source se trouve sur le disque à effacer.' }
    }
    Invoke-RestMethod -Uri "$endpoint/claim" -Method Post -Headers $headers | Out-Null
    $started = $true
    Send-Event 'running' 5 'Agent WinPE identifié ; contrôle de l''image source'
    $checksum = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($checksum -ne $plan.image_sha256) { throw 'Le SHA-256 de l''image ne correspond pas au profil autorisé.' }
    # DismCmdlets rejects a missing edition/index before touching the disk.
    $edition = Get-WindowsImage -ImagePath $source.FullName -Index $plan.image_index
    if ($edition.Architecture -ne 9) { throw 'Une image Windows x64 est requise.' }
    if ($edition.Languages -and $plan.locale -notin @($edition.Languages)) { throw 'La langue du profil n est pas presente dans cette image Windows.' }
    $manufacturer = [string](Get-CimInstance Win32_ComputerSystem).Manufacturer
    $selectedApplications = @($plan.applications | Where-Object { Test-AtelierManufacturer $_.manufacturer $manufacturer })
    $sourceFolder = Split-Path $source.FullName -Parent
    $extraFiles = New-Object 'System.Collections.Generic.List[object]'
    foreach ($application in $selectedApplications) {
        $extraFiles.Add([pscustomobject]@{asset=$application.asset; subfolder='Packages'})
    }
    if ($plan.wallpaper) { $extraFiles.Add([pscustomobject]@{asset=$plan.wallpaper; subfolder='Resources'}) }
    foreach ($extra in $extraFiles) {
        $path = Join-Path $sourceFolder $extra.asset.filename
        $file = Get-Item -LiteralPath $path
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $extra.asset.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $extra.asset.sha256) {
            throw ("Fichier supplementaire invalide avant effacement : " + $extra.asset.filename)
        }
    }
    $unattend = New-AtelierUnattend -Plan $plan
    Assert-AtelierUnattendContent -Content $unattend
    Write-Host "IMAGE : $($edition.ImageName)"
    Write-Host "CIBLE : $($plan.hostname) / $($plan.mac)"
    Write-Host "DISQUE : $($disk.Number) / $($disk.FriendlyName) / série $($disk.SerialNumber) / $([math]::Round($disk.Size/1GB)) Go" -ForegroundColor Yellow
    Write-Host 'Toutes les partitions de ce disque seront supprimées.' -ForegroundColor Red
    $expected = "EFFACER $($plan.hostname) DISQUE $($disk.Number)"
    $confirmation = if ($StartFromWizard -and $plan.internal_mode) { $expected } elseif ($LocalConfirmation) { $LocalConfirmation } else { Read-Host "Tapez exactement : $expected" }
    if ($confirmation -cne $expected) { throw 'Confirmation locale refusée ; aucun disque effacé.' }
    Assert-Active
    # Hold the source open for read and disallow writes/deletion during apply.
    $imageLock = [IO.File]::Open($source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ((Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $plan.image_sha256) { throw 'L''image a changé après sa validation.' }
        Send-Event 'running' 20 'Image vérifiée ; création des partitions UEFI/GPT'
        Assert-Active
        $currentDisk = Get-Disk -Number $plan.disk_number
        if ($currentDisk.UniqueId -ne $disk.UniqueId -or $currentDisk.Size -ne $disk.Size) { throw 'L''identité du disque a changé.' }
        $partitionScript = @"
select disk $($plan.disk_number)
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=1024
format quick fs=ntfs label="Windows"
assign letter=W
create partition primary
format quick fs=ntfs label="Recovery"
assign letter=R
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
exit
"@
        $partitionPath = Join-Path $env:TEMP 'atelier-partitions.txt'
        Set-Content -LiteralPath $partitionPath -Value $partitionScript -Encoding ASCII
        try { Run-Checked 'diskpart.exe' @('/s', $partitionPath) } finally { Remove-Item $partitionPath -ErrorAction SilentlyContinue }
        Wait-AtelierTargetPartitions -DiskNumber $disk.Number -ExpectedUniqueId ([string]$disk.UniqueId) -ExpectedSize $disk.Size
        Assert-Active
        Send-Event 'running' 35 'Application de l''image Windows (DISM)'
        Run-Checked 'dism.exe' @('/Apply-Image', "/ImageFile:$($source.FullName)", "/Index:$($plan.image_index)", '/ApplyDir:W:\', '/CheckIntegrity', '/Verify')
    } finally { $imageLock.Dispose() }
    Assert-Active
    Send-Event 'running' 80 'Configuration du nom du poste et du démarrage UEFI'
    $payloadPath = 'W:\ProgramData\AtelierPXE'
    New-Item -ItemType Directory -Path $payloadPath -Force | Out-Null
    Run-Checked 'icacls.exe' @($payloadPath, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    Copy-Item (Join-Path $PSScriptRoot 'FirstLogon.ps1'), (Join-Path $PSScriptRoot 'Unattend.ps1'), (Join-Path $PSScriptRoot 'Prepare-Windows.ps1'), (Join-Path $PSScriptRoot 'Maintenance.ps1'), (Join-Path $PSScriptRoot 'Progress.ps1'), (Join-Path $PSScriptRoot 'Updates.ps1'), (Join-Path $PSScriptRoot 'Prepare-IQTools.ps1'), (Join-Path $PSScriptRoot 'Test-Batterie.ps1'), (Join-Path $PSScriptRoot 'Verifier-Licence.ps1') -Destination $payloadPath
    $personalization = @{settings=$plan.settings; applications=$selectedApplications; wallpaper=$plan.wallpaper} | ConvertTo-Json -Depth 12
    Write-AtelierVerifiedUtf8File -Path (Join-Path $payloadPath 'personalization.json') -Content $personalization | Out-Null
    foreach ($extra in $extraFiles) {
        Assert-Active
        Send-Event 'running' 85 ('Preparation du bundle : ' + $extra.asset.filename)
        $folder = Join-Path $payloadPath $extra.subfolder
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        if ($extra.subfolder -eq 'Resources') {
            # Explorer runs without elevation, even for an administrator account.
            Run-Checked 'icacls.exe' @($folder, '/grant:r', '*S-1-5-32-545:(OI)(CI)RX')
        }
        $target = Join-Path $folder $extra.asset.filename
        Copy-Item -LiteralPath (Join-Path $sourceFolder $extra.asset.filename) -Destination $target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $extra.asset.sha256) { throw 'Integrite du bundle refusee apres copie.' }
    }
    # specialize/oobeSystem are processed at first boot, not by DISM's
    # offlineServicing pass. Cache the answer file for Windows setup.
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    $answerBackup = Write-AtelierVerifiedUtf8File -Path (Join-Path $payloadPath 'Unattend.generated.xml') -Content $unattend -Unattend
    $answer = Write-AtelierVerifiedUtf8File -Path 'W:\Windows\Panther\Unattend.xml' -Content $unattend -Unattend
    $answerManifest = @{hostname=$plan.hostname;locale=$plan.locale;size_bytes=$answer.size_bytes;sha256=$answer.sha256;backup='Unattend.generated.xml'} | ConvertTo-Json
    Write-AtelierVerifiedUtf8File -Path (Join-Path $payloadPath 'unattend-manifest.json') -Content $answerManifest | Out-Null
    Run-Checked 'W:\Windows\System32\bcdboot.exe' @('W:\Windows', '/s', 'S:', '/f', 'UEFI')
    $winre = 'W:\Windows\System32\Recovery\Winre.wim'
    if (Test-Path $winre) {
        New-Item -ItemType Directory -Path 'R:\Recovery\WindowsRE' -Force | Out-Null
        Copy-Item $winre 'R:\Recovery\WindowsRE\Winre.wim'
        Run-Checked 'W:\Windows\System32\reagentc.exe' @('/SetReImage', '/Path', 'R:\Recovery\WindowsRE', '/Target', 'W:\Windows')
    }
    Assert-Active
    Assert-AtelierUnattendFile -Path $answer.path -ExpectedHash $answer.sha256
    Assert-AtelierUnattendFile -Path $answerBackup.path -ExpectedHash $answerBackup.sha256
    Send-Event 'staged' 100 'Image appliquee et bundle prepare. Premier demarrage, logiciels, bureau et OOBE restent a valider.'
    Write-Host 'Installation préparée. Vérifiez le journal, puis redémarrez avec wpeutil reboot. Le premier démarrage Windows reste à contrôler.' -ForegroundColor Green
} catch {
    $failure = $_
    if ($started) {
        try { Send-Event 'failed' $lastProgress $failure.Exception.Message } catch { Write-Warning 'Impossible de transmettre l''échec à la console.' }
    }
    Write-Error $failure -ErrorAction Continue
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
    $headers.Clear()
    $Token = $null
}
