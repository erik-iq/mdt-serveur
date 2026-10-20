#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE')
$ErrorActionPreference = 'Stop'
$resultPath = Join-Path $DataPath 'result.json'
$logPath = Join-Path $DataPath 'first-logon.log'
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
    # Old clients used an interactive task to open HPIA after maintenance.
    Unregister-ScheduledTask -TaskName 'AtelierPXE-Tools' -Confirm:$false -ErrorAction SilentlyContinue
    $detail=if ($script:softwareSummary.status -eq 'needs_attention') { 'Logiciels non installes ou non verifies : '+($script:softwareSummary.missing -join ', ')+'.' } else { 'Logiciels verifies : '+$script:softwareSummary.verified+'.' }
    Set-Progress 'running' 75 ($detail+' Finalisation et rapport en arriere-plan ; mises a jour Windows / Store manuelles.')
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
    if ($payload.deployment.cleanup_after_reporting) {
        $self=Get-Process -Id $PID
        @{pid=$PID;started=$self.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $DataPath 'preparation-worker.json') -Encoding UTF8
    }
    # Always check the requested applications against this Windows installation.
    # Captured WIMs and resumed clients may contain obsolete success files.
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
        $wallpaperSource = Join-Path $DataPath ('Resources\' + $payload.wallpaper.filename)
        Assert-FileHash $wallpaperSource $payload.wallpaper.sha256
        $wallpaperDirectory=Join-Path $env:SystemDrive 'IQ_\Personnalisation'
        New-Item -ItemType Directory -Path $wallpaperDirectory -Force | Out-Null
        $wallpaper=Join-Path $wallpaperDirectory $payload.wallpaper.filename
        Copy-Item -LiteralPath $wallpaperSource -Destination $wallpaper -Force
        Assert-FileHash $wallpaper $payload.wallpaper.sha256
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallpaper
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class AtelierWallpaper { [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SystemParametersInfo(int action,int parameter,string value,int flags); }'
        if (-not [AtelierWallpaper]::SystemParametersInfo(20,0,$wallpaper,3)) { throw 'Impossible de rafraichir le fond d ecran.' }
        Write-Trace 'Fond d ecran applique.'
    }
    . (Join-Path $DataPath 'Client-Software.ps1')
    $hpWinGetTool=$null
    $clientPackages=@()
    if ($payload.settings.software_mode -eq 'winget') { $clientPackages=@($payload.settings.winget_packages) }
    if ($clientPackages.Count) {
        $softwareTiming=Start-AtelierTiming $DataPath 'software'
        foreach ($entry in @(Install-AtelierClientSoftware -DataPath $DataPath -Packages $clientPackages -OnProgress { param($Percent,$Message);Set-Progress 'running' $Percent $Message })) {
            $results.Add($entry)
            if ($entry.exit_code -in @(3010,1641)) { $restartNeeded=$true }
            if ($entry.id -eq 'hpia' -and $entry.status -eq 'completed') { $hpWinGetTool=$entry.tool }
        }
    }
    if ($softwareTiming) { Stop-AtelierTiming $DataPath $softwareTiming;Sync-AtelierTimings $DataPath }
    $appIndex = 0
    $readyTools=New-Object 'Collections.Generic.List[object]'
    if ($hpWinGetTool) { $readyTools.Add($hpWinGetTool) }
    $checkpointPath=Join-Path $DataPath 'packages-state.json'
    $checkpoints=@{}
    if (Test-Path $checkpointPath) {
        $checkpointEntries=Get-Content $checkpointPath -Encoding UTF8 -Raw | ConvertFrom-Json
        foreach ($entry in $checkpointEntries) { $checkpoints[$entry.id]=$entry }
    }
    $toolsTiming=Start-AtelierTiming $DataPath 'manufacturer_tools'
    $applicationsToPrepare=@($payload.applications | Where-Object { -not ($_.manufacturer -eq 'hp' -and ([IO.Path]::GetFileName([string]$_.entry_point) -ieq 'HPImageAssistant.exe')) })
    if ($payload.settings.software_mode -eq 'winget') {
        $applicationsToPrepare=@()
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
    Stop-AtelierTiming $DataPath $toolsTiming
    Sync-AtelierTimings $DataPath
    Set-Progress 'running' 65 'Creation du dossier C:\IQ_ et des diagnostics...'
    & (Join-Path $DataPath 'Prepare-IQTools.ps1') -DataPath $DataPath
    # Export once at finalization, after software and updates; no duplicate CIM scan.
    $script:softwareSummary=Get-AtelierSoftwareSummary -Packages $clientPackages -Results @($results.ToArray())
    $softwareStatus=if (@($results | Where-Object { $_.status -eq 'failed' }).Count) { 'needs_attention' } else { $script:softwareSummary.status }
    @{status='completed';software_status=$softwareStatus;software_summary=$script:softwareSummary;deployment_id=[string]$payload.deployment.id;timestamp=(Get-Date).ToString('o'); restart_needed=$restartNeeded; applications=@($results.ToArray())} | ConvertTo-Json -Depth 8 | Set-Content $resultPath -Encoding UTF8
    Start-Maintenance
    Write-Trace 'Personnalisation terminee. Consultez result.json pour les logiciels et le redemarrage eventuel.'
} catch {
    if ($softwareTiming) { Stop-AtelierTiming $DataPath $softwareTiming 'failed' }
    if ($toolsTiming) { Stop-AtelierTiming $DataPath $toolsTiming 'failed' }
    Sync-AtelierTimings $DataPath
    @{status='failed'; timestamp=(Get-Date).ToString('o'); message=$_.Exception.Message; applications=@($results.ToArray())} | ConvertTo-Json -Depth 6 | Set-Content $resultPath -Encoding UTF8
    Set-Progress 'failed' 0 ('Preparation interrompue : ' + $_.Exception.Message)
    . (Join-Path $DataPath 'Updates.ps1')
    if ($payload.settings.unattended) { Disable-AtelierAutoLogon }
    Complete-AtelierReport $DataPath
    Write-Trace ('Echec : ' + $_.Exception.Message)
    throw
}
