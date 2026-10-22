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
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$headers = @{ Authorization = "Bearer $Token" }
$ServerUrl = $ServerUrl.TrimEnd('/')
$endpoint = "$ServerUrl/api/agent/$DeploymentId"
$lastProgress = 0
$started = $false
$staged = $false
$imageLock = $null
. (Join-Path $PSScriptRoot 'Timings.ps1')
$timingPath=Join-Path $env:TEMP ('AtelierTiming-'+[guid]::NewGuid().ToString('N'))
$mutex = $null
$ownsMutex = $false
. (Join-Path $PSScriptRoot 'Unattend.ps1')
. (Join-Path $PSScriptRoot 'Partitions.ps1')
. (Join-Path $PSScriptRoot 'WinPE-Session.ps1')

function Send-Event([string]$Status, [int]$Percent, [string]$Message) {
    $body = @{status=$Status; progress=$Percent; message=$Message} | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$endpoint/events" -Method Post -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    $script:lastProgress = $Percent
    Write-Information -MessageData ("ATELIER|$Percent|$Message") -InformationAction Continue
}
function Run-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable a retourne le code $LASTEXITCODE" }
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
    if ($plan.status -ne 'queued') { throw 'Ce déploiement a déjà été commence ; créez une nouvelle autorisation après diagnostic.' }
    Assert-AtelierMachineIdentity $plan
    Run-Checked 'wpeutil.exe' @('UpdateBootInfo')
    $firmware = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType).PEFirmwareType
    if ($firmware -ne 2) { throw 'Le déploiement nécessite un démarrage UEFI (BIOS legacy non pris en charge).' }
    $disk = Get-Disk -Number $plan.disk_number
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.IsOffline -or $disk.IsReadOnly -or $disk.BusType -eq 'USB') { throw 'Disque système, USB, hors ligne ou en lecture seule : opération refusée.' }
    if ($disk.Size -lt 64GB) { throw 'Un disque de 64 Go minimum est requis.' }
    foreach ($letter in @('S','W','R')) {
        if (Test-Path "${letter}:\") { throw "La lettre $letter est occupee. Liberez-la avant le déploiement." }
    }
    $source = Get-Item -LiteralPath $ImagePath
    if ($source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $source.Name -ne $plan.image_filename -or $source.Length -ne $plan.image_size -or $source.Extension -ne '.wim') { throw 'La source doit être le fichier WIM enregistre dans la console.' }
    if ($source.FullName -notmatch '^\\\\') {
        $sourceDisk = Get-Partition -DriveLetter $source.FullName.Substring(0,1) | Get-Disk
        if ($sourceDisk.Number -eq $disk.Number) { throw 'L''image source se trouve sur le disque a effacer.' }
    }
    $claim = Invoke-RestMethod -Uri "$endpoint/claim" -Method Post -Headers $headers
    $started = $true
    if (-not $claim.report_token -or -not $claim.report_expires) { throw 'Mettre à jour la console ATELIER-2 avant de déployer cette image WinPE. Aucun disque effacé.' }
    Send-Event 'running' 5 'Agent WinPE identifie ; contrôle de l''image source'
    # Le serveur calcule l’empreinte à l’enregistrement. Éviter une relecture complète par SMB.
    # Garder la source immuable pendant la validation et l’application DISM.
    $imageLock = [IO.File]::Open($source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    # DismCmdlets refuse une édition ou un index absent avant toute écriture sur le disque.
    $edition = Get-WindowsImage -ImagePath $source.FullName -Index $plan.image_index
    if ($edition.Architecture -ne 9) { throw 'Une image Windows x64 est requise.' }
    $expectedEdition=@{Pro='Professional';Professional='Professional';Famille='Core';Home='Core';'Famille unilingue'='CoreSingleLanguage'}[$plan.edition]
    if ($expectedEdition -and $edition.EditionId -ne $expectedEdition) { throw 'L''index WIM ne correspond pas à l''édition Pro/Famille du profil. Synchroniser les profils avant de poursuivre.' }
    if ($edition.Languages -and $plan.locale -notin @($edition.Languages)) { throw 'La langue du profil n''est pas présenté dans cette image Windows.' }
    $manufacturer = [string](Get-CimInstance Win32_ComputerSystem).Manufacturer
    $selectedApplications = @($plan.applications | Where-Object { $plan.settings.software_mode -ne 'winget' } | Where-Object { Test-AtelierManufacturer $_.manufacturer $manufacturer })
    $sourceFolder = Split-Path $source.FullName -Parent
    $extraFiles = New-Object 'System.Collections.Generic.List[object]'
    foreach ($application in $selectedApplications) {
        $extraFiles.Add([pscustomobject]@{asset=$application.asset; subfolder='Packages'})
    }
    if ($plan.wallpaper) { $extraFiles.Add([pscustomobject]@{asset=$plan.wallpaper; subfolder='Resources'}) }
    foreach ($extra in $extraFiles) {
        $path = Join-Path $sourceFolder $extra.asset.filename
        $file = Get-Item -LiteralPath $path
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $extra.asset.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -ne $extra.asset.sha256) {
            throw ("Fichier supplémentaire invalide avant effacement : " + $extra.asset.filename)
        }
    }
    $unattend = New-AtelierUnattend -Plan $plan
    Assert-AtelierUnattendContent -Content $unattend
    Write-Host "IMAGE : $($edition.ImageName)"
    Write-Host "CIBLE : $($plan.hostname) / SN $($plan.serial_number)"
    Write-Host "DISQUE : $($disk.Number) / $($disk.FriendlyName) / série $($disk.SerialNumber) / $([math]::Round($disk.Size/1GB)) Go" -ForegroundColor Yellow
    Write-Host 'Toutes les partitions de ce disque seront supprimées.' -ForegroundColor Red
    $expected = "EFFACER $($plan.hostname) DISQUE $($disk.Number)"
    $confirmation = if ($StartFromWizard -and $plan.internal_mode) { $expected } elseif ($LocalConfirmation) { $LocalConfirmation } else { Read-Host "Tapez exactement : $expected" }
    if ($confirmation -cne $expected) { throw 'Confirmation locale refusée ; aucun disque effacé.' }
    Assert-Active
    Assert-AtelierMachineIdentity $plan
    # Garder la source ouverte en lecture, sans autoriser son écriture ou sa suppression.
    try {
        Send-Event 'running' 20 'Image vérifiée ; création des partitions UEFI/GPT'
        Assert-Active
        $currentDisk = Get-Disk -Number $plan.disk_number
        if ($currentDisk.UniqueId -ne $disk.UniqueId -or $currentDisk.Size -ne $disk.Size) { throw 'L''identité du disque a change.' }
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
        $imageTiming=Start-AtelierTiming $timingPath 'image' 'winpe'
        Run-Checked 'dism.exe' @('/Apply-Image', "/ImageFile:$($source.FullName)", "/Index:$($plan.image_index)", '/ApplyDir:W:\', '/CheckIntegrity', '/Verify')
        Stop-AtelierTiming $timingPath $imageTiming
        Sync-AtelierTimings $timingPath ([pscustomobject]@{server_url=$ServerUrl.TrimEnd('/');id=$DeploymentId;token=$claim.report_token})
    } finally { if ($imageLock) { $imageLock.Dispose(); $imageLock=$null } }
    Assert-Active
    Send-Event 'running' 80 'Configuration du nom du poste et du démarrage UEFI'
    $payloadPath = 'W:\ProgramData\AtelierPXE'
    # Un WIM capturé peut contenir des checkpoints de son ordinateur de référence.
    # Les conserver hors du nouveau dossier de travail, sans réutiliser leurs statuts de réussite.
    $previousPayload=Initialize-AtelierDeploymentPayload -Path $payloadPath
    Run-Checked 'icacls.exe' @($payloadPath, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    Copy-Item (Join-Path $PSScriptRoot 'FirstLogon.ps1'), (Join-Path $PSScriptRoot 'Unattend.ps1'), (Join-Path $PSScriptRoot 'Prepare-Windows.ps1'), (Join-Path $PSScriptRoot 'Maintenance.ps1'), (Join-Path $PSScriptRoot 'Progress.ps1'), (Join-Path $PSScriptRoot 'Updates.ps1'), (Join-Path $PSScriptRoot 'Prepare-IQTools.ps1'), (Join-Path $PSScriptRoot 'Test-Batterie.ps1'), (Join-Path $PSScriptRoot 'Verifier-Licence.ps1') -Destination $payloadPath
    foreach ($name in @('Reporting.ps1','New-DeploymentReport.ps1','Launch-Tools.ps1','HP-ImageAssistant.ps1','Test-HPIA.ps1','Tester-HPIA.cmd','HP-Repository.ps1','HP-ClientRepository.ps1','HP-Reports.ps1','Test-Materiel.ps1','Tests-Materiel.html','Verifier-Garantie.ps1','Export-Inventaire.ps1','Client-Software.ps1','Install-WinGet.ps1','software-sources.json','Inventory-Transfer.ps1','Finalization.ps1','Timings.ps1','Start-Preparation.ps1','IQ-Paths.ps1','Theme.ps1','theme.json','brand-logo.png')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $payloadPath }
    if (Test-Path (Join-Path $timingPath 'timings')) { Copy-Item -LiteralPath (Join-Path $timingPath 'timings') -Destination $payloadPath -Recurse -Force }
    $publicRoot=Join-Path $PSScriptRoot 'trusted-root.cer'
    if (Test-Path -LiteralPath $publicRoot) { Copy-Item -LiteralPath $publicRoot -Destination $payloadPath }
    $reporting=@{server_url=$ServerUrl.TrimEnd('/');id=$plan.id;token=$claim.report_token;expires=$claim.report_expires} | ConvertTo-Json
    Write-AtelierVerifiedUtf8File -Path (Join-Path $payloadPath 'reporting.json') -Content $reporting | Out-Null
    $personalization = @{tools=$plan.tools;settings=$plan.settings; applications=$selectedApplications; wallpaper=$plan.wallpaper;deployment=@{id=$plan.id;serial_number=$plan.serial_number;cleanup_after_reporting=$true;hp_repository=$true;allow_bios_restart=$true;previous_payload_name=$(if($previousPayload){Split-Path $previousPayload -Leaf}else{''});profile_name=$plan.profile_name;image_filename=$plan.image_filename;image_index=$plan.image_index;winpe_staged_utc=[DateTime]::UtcNow.ToString('o')}} | ConvertTo-Json -Depth 12
    Write-AtelierVerifiedUtf8File -Path (Join-Path $payloadPath 'personalization.json') -Content $personalization | Out-Null
    foreach ($extra in $extraFiles) {
        Assert-Active
        Send-Event 'running' 85 ('Préparation du bundle : ' + $extra.asset.filename)
        $folder = Join-Path $payloadPath $extra.subfolder
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        if ($extra.subfolder -eq 'Resources') {
            # Explorer s’exécute sans élévation, même dans un compte administrateur.
            Run-Checked 'icacls.exe' @($folder, '/grant:r', '*S-1-5-32-545:(OI)(CI)RX')
        }
        $target = Join-Path $folder $extra.asset.filename
        Copy-Item -LiteralPath (Join-Path $sourceFolder $extra.asset.filename) -Destination $target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -ne $extra.asset.sha256) { throw 'Intégrité du bundle refusée après copie.' }
    }
    # specialize/oobeSystem sont traités au premier démarrage, et non pendant
    # offlineServicing. Mettre le fichier de réponses en cache pour Windows Setup.
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
    Send-Event 'staged' 100 'Image appliquée. Redémarrage automatique vers Windows ; installation des logiciels au premier démarrage.'
    $staged = $true
    Write-Host 'Image et démarrage préparés. Redémarrage automatique dans 5 secondes.' -ForegroundColor Green
} catch {
    $failure = $_
    if ($imageTiming) {
        Stop-AtelierTiming $timingPath $imageTiming 'failed'
        Sync-AtelierTimings $timingPath ([pscustomobject]@{server_url=$ServerUrl.TrimEnd('/');id=$DeploymentId;token=$claim.report_token})
    }
    if ($started) {
        try { Send-Event 'failed' $lastProgress $failure.Exception.Message } catch { Write-Warning 'Impossible de transmettre l''échec à la console.' }
    }
    Write-Error $failure -ErrorAction Continue
    exit 1
} finally {
    if ($imageLock) { $imageLock.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
    $headers.Clear()
    $Token = $null
}
# Vérifier les fichiers de réponses et fermer leurs handles avant de demander le redémarrage.
Restart-AtelierStagedWindows -Staged $staged
