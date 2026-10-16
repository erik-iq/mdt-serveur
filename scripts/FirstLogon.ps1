#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE')
$ErrorActionPreference = 'Stop'
$resultPath = Join-Path $DataPath 'result.json'
$logPath = Join-Path $DataPath 'first-logon.log'
$previous = if (Test-Path $resultPath) { Get-Content $resultPath -Encoding UTF8 -Raw | ConvertFrom-Json } else { $null }
$payload = Get-Content (Join-Path $DataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
. (Join-Path $DataPath 'Unattend.ps1')
. (Join-Path $DataPath 'Reporting.ps1')
$manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
$results = New-Object 'System.Collections.Generic.List[object]'
$restartNeeded = $false
function Set-Progress([string]$Status,[int]$Percent,[string]$Message) {
    Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'progress.json') -Content (@{status=$Status;progress=$Percent;message=$Message;timestamp=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json) -NoBackup | Out-Null
    Send-AtelierWindowsProgress $DataPath $Status $Percent $Message
}
function Start-Maintenance {
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $DataPath 'Maintenance.ps1') + '"')
    $triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 14)))
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'AtelierPXE-Maintenance' -Action $action -Trigger $triggers -Principal $principal -Settings $taskSettings -Force | Out-Null
    # Maintenance runs in SYSTEM; the open desktop remains available throughout.
    . (Join-Path $DataPath 'Updates.ps1')
    Disable-AtelierAutoLogon
    $userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $toolsAction=New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $DataPath 'Launch-Tools.ps1') + '"')
    $toolsPrincipal=New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Highest
    $toolsTriggers=@((New-ScheduledTaskTrigger -AtLogOn -User $userSid),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 14)))
    Register-ScheduledTask -TaskName 'AtelierPXE-Tools' -Action $toolsAction -Trigger $toolsTriggers -Principal $toolsPrincipal -Settings (New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew) -Force | Out-Null
    Set-Progress 'running' 75 'Logiciels et bureau prepares. Les mises a jour vont commencer...'
    Start-ScheduledTask -TaskName 'AtelierPXE-Maintenance'
    Unregister-ScheduledTask -TaskName 'AtelierPXE-Preparation' -Confirm:$false -ErrorAction SilentlyContinue
}


function Write-Trace([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $Message
}
function Assert-FileHash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "Integrite du fichier refusee : $Path"
    }
}
function Expand-SafeZip([string]$Path, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $size = 0L
        foreach ($entry in $zip.Entries) {
            $size += $entry.Length
            if ($size -gt 25GB) { throw 'Archive trop volumineuse apres extraction.' }
            $target = [IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName -match '[:\x00]') {
                throw 'Chemin dangereux dans le ZIP.'
            }
            if (-not $entry.Name) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
}
function Invoke-Installer([string]$Executable, [string]$Arguments, [string]$WorkingDirectory) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { Split-Path $Executable -Parent }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(2700000)) { throw 'Installateur encore actif apres 45 minutes : consultez le processus avant toute reprise.' }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

try {
    # This task is detached from OOBE. Wait for Explorer without blocking sign-in.
    $desktopDeadline=(Get-Date).AddSeconds(60)
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and (Get-Date) -lt $desktopDeadline) { Start-Sleep -Seconds 1 }
    Initialize-AtelierReportTrust -DataPath $DataPath
    if ($previous -and $previous.status -eq 'completed') { Start-Maintenance; return }
    Set-Progress 'running' 5 'Preparation du bureau et des logiciels...'
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powerShell -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $DataPath 'Progress.ps1') + '"') | Out-Null
    Write-Trace 'Debut de la personnalisation du premier compte administrateur.'
    $theme = $payload.settings.theme
    if ($theme -in @('light','dark')) {
        $registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        New-Item -Path $registry -Force | Out-Null
        $value = if ($theme -eq 'light') { 1 } else { 0 }
        New-ItemProperty -Path $registry -Name AppsUseLightTheme -Value $value -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $registry -Name SystemUsesLightTheme -Value $value -PropertyType DWord -Force | Out-Null
    }
    if ($payload.wallpaper) {
        $wallpaper = Join-Path $DataPath ('Resources\' + $payload.wallpaper.filename)
        Assert-FileHash $wallpaper $payload.wallpaper.sha256
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallpaper
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class AtelierWallpaper { [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SystemParametersInfo(int action,int parameter,string value,int flags); }'
        if (-not [AtelierWallpaper]::SystemParametersInfo(20,0,$wallpaper,3)) { throw 'Impossible de rafraichir le fond d ecran.' }
        Write-Trace 'Fond d ecran applique.'
    }
    if ($payload.settings.software_mode -eq 'winget') {
        . (Join-Path $DataPath 'Client-Software.ps1')
        foreach ($entry in @(Install-AtelierClientSoftware -DataPath $DataPath -Packages @($payload.settings.winget_packages) -OnProgress { param($Percent,$Message);Set-Progress 'running' $Percent $Message })) {
            $results.Add($entry)
            if ($entry.exit_code -in @(3010,1641)) { $restartNeeded=$true }
        }
    }
    $appIndex = 0
    $readyTools=New-Object 'Collections.Generic.List[object]'
    $checkpointPath=Join-Path $DataPath 'packages-state.json'
    $checkpoints=@{}
    if (Test-Path $checkpointPath) {
        foreach ($entry in @(Get-Content $checkpointPath -Encoding UTF8 -Raw | ConvertFrom-Json)) { $checkpoints[$entry.id]=$entry }
    }
    $applicationsToPrepare=@($payload.applications)
    if ($payload.settings.software_mode -eq 'winget') {
        $applicationsToPrepare=@()
        foreach ($tool in @($payload.tools)) {
            if (-not $tool -or -not (Test-AtelierManufacturer $tool.manufacturer $manufacturer)) { continue }
            try {
                Set-Progress 'running' 58 ('Telechargement de l outil constructeur : ' + $tool.name)
                $folder=Join-Path $DataPath 'Packages'
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                $target=Join-Path $folder $tool.asset.filename
                $reporter=Get-Content (Join-Path $DataPath 'reporting.json') -Encoding UTF8 -Raw | ConvertFrom-Json
                if (-not (Test-Path $target)) {
                    Invoke-WebRequest -UseBasicParsing -Uri ($reporter.server_url + '/api/windows/' + $reporter.id + '/tools/' + $tool.asset.id) -Headers @{Authorization=('Bearer ' + $reporter.token)} -OutFile $target -TimeoutSec 300 | Out-Null
                }
                Assert-FileHash $target $tool.asset.sha256
                $applicationsToPrepare += $tool
            } catch { if ($target -and (Test-Path $target)) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue };$results.Add(@{name=$tool.name;status='failed';reason='Outil constructeur a preparer manuellement ; consulter first-logon.log.'});Write-Trace $_.Exception.Message }
        }
    }
    foreach ($application in $applicationsToPrepare) {
        $appIndex++
        Set-Progress 'running' (10 + [int](50 * $appIndex / [math]::Max(1,$applicationsToPrepare.Count))) ('Installation de ' + $application.name + '...')
        if (-not (Test-AtelierManufacturer $application.manufacturer $manufacturer)) {
            $results.Add(@{name=$application.name; status='skipped'; reason='Autre constructeur'})
            Write-Trace ("Outil ignore pour ce constructeur : " + $application.name)
            continue
        }
        $asset = $application.asset
        if ($application.install_mode -ne 'portable' -and $checkpoints.ContainsKey($application.id) -and $checkpoints[$application.id].sha256 -eq $asset.sha256) {
            $results.Add($checkpoints[$application.id]); $restartNeeded=$restartNeeded -or $checkpoints[$application.id].exit_code -eq 3010
            Write-Trace ('Logiciel deja prepare et verifie : ' + $application.name)
            continue
        }
        $source = Join-Path $DataPath ('Packages\' + $asset.filename)
        Assert-FileHash $source $asset.sha256
        $executable = $source
        if ([IO.Path]::GetExtension($source) -eq '.zip') {
            $folder = if ($application.install_mode -eq 'portable') {
                Join-Path $env:ProgramFiles ('AtelierPXE\Tools\' + $application.id)
            } else { Join-Path $DataPath ('Expanded\' + $application.id) }
            Expand-SafeZip $source $folder
            $executable = [IO.Path]::GetFullPath((Join-Path $folder $application.entry_point))
            if (-not $executable.StartsWith(([IO.Path]::GetFullPath($folder).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Point d entree hors du bundle.' }
        }
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw ("Installateur absent : " + $application.name) }
        $signature = Get-AuthenticodeSignature -LiteralPath $executable
        if ($signature.Status -ne 'Valid') { throw ("Signature editeur invalide : " + $application.name) }
        if ($application.install_mode -eq 'portable') {
            $shell = New-Object -ComObject WScript.Shell
            try {
                $safeName = $application.name -replace '[^\p{L}\p{N} _-]', '_'
                $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) ($safeName + '.lnk')))
                $shortcut.TargetPath = $executable
                $shortcut.WorkingDirectory = Split-Path $executable -Parent
                $shortcut.Save()
            } finally { if ($shell) { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } }
            $exitCode = 0
            if ($application.manufacturer -eq 'hp' -and ([IO.Path]::GetFileName($executable) -ieq 'HPImageAssistant.exe')) {
                $readyTools.Add(@{name=$application.name;path=$executable;sha256=(Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()})
            }
        } elseif ([IO.Path]::GetExtension($executable) -eq '.msi') {
            $installerLog = Join-Path $DataPath ('msi-' + $application.id + '.log')
            $arguments = '/i "{0}" /qn /norestart /L*v "{1}" {2}' -f $executable, $installerLog, $application.arguments
            $exitCode = Invoke-Installer (Join-Path $env:SystemRoot 'System32\msiexec.exe') $arguments (Split-Path $executable -Parent)
        } else { $exitCode = Invoke-Installer $executable $application.arguments }
        if ($exitCode -notin @(0,3010)) { throw ("Echec de " + $application.name + " (code $exitCode)") }
        if ($exitCode -eq 3010) { $restartNeeded = $true }
        $entry=@{id=$application.id;sha256=$asset.sha256;name=$application.name;version=$application.version;status='completed';exit_code=$exitCode}
        $results.Add($entry); $checkpoints[$application.id]=$entry
        Write-AtelierVerifiedUtf8File -Path $checkpointPath -Content (ConvertTo-Json -InputObject @($checkpoints.Values) -Depth 6) -NoBackup | Out-Null
        Write-Trace ("Logiciel prepare : " + $application.name)
    }
    Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'ready-tools.json') -Content (ConvertTo-Json -InputObject @($readyTools.ToArray()) -Depth 4) -NoBackup | Out-Null
    Set-Progress 'running' 65 'Creation du dossier C:\IQ_ et des diagnostics...'
    & (Join-Path $DataPath 'Prepare-IQTools.ps1') -DataPath $DataPath
    # Export once at finalization, after software and updates; no duplicate CIM scan.
    $softwareStatus=if (@($results | Where-Object { $_.status -eq 'failed' }).Count) { 'needs_attention' } else { 'completed' }
    @{status='completed';software_status=$softwareStatus; timestamp=(Get-Date).ToString('o'); restart_needed=$restartNeeded; applications=@($results.ToArray())} | ConvertTo-Json -Depth 6 | Set-Content $resultPath -Encoding UTF8
    Start-Maintenance
    Write-Trace 'Personnalisation terminee. Consultez result.json pour les logiciels et le redemarrage eventuel.'
} catch {
    @{status='failed'; timestamp=(Get-Date).ToString('o'); message=$_.Exception.Message; applications=@($results.ToArray())} | ConvertTo-Json -Depth 6 | Set-Content $resultPath -Encoding UTF8
    Set-Progress 'failed' 0 ('Preparation interrompue : ' + $_.Exception.Message)
    . (Join-Path $DataPath 'Updates.ps1')
    if ($payload.settings.unattended) { Disable-AtelierAutoLogon }
    Complete-AtelierReport $DataPath
    Write-Trace ('Echec : ' + $_.Exception.Message)
    throw
}
