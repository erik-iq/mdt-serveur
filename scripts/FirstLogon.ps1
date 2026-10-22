#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE', [string]$ToolsPath = 'C:\IQ_')
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

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
    $triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 14)))
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'AtelierPXE-Maintenance' -Action $action -Trigger $triggers -Principal $principal -Settings $taskSettings -Force | Out-Null
    # La maintenance s’exécute sous SYSTEM ; le bureau reste disponible.
    . (Join-Path $DataPath 'Updates.ps1')
    Disable-AtelierAutoLogon
    # Les anciens postes utilisaient une tâche interactive pour ouvrir HPIA après maintenance.
    Unregister-ScheduledTask -TaskName 'AtelierPXE-Tools' -Confirm:$false -ErrorAction SilentlyContinue
    $detail=if ($script:softwareSummary.status -eq 'needs_attention') { 'Logiciels non installés ou non vérifiés : '+($script:softwareSummary.missing -join ', ')+'.' } else { 'Logiciels vérifiés : '+$script:softwareSummary.verified+'.' }
    Set-Progress 'running' 75 ($detail+' Finalisation et pilotes constructeur en arrière-plan.')
    # Cette copie IQ survit au nettoyage et affiche le bilan après reconnexion.
    $uiRoot=Join-Path $ToolsPath 'Rapports\Preparation'
    New-Item -ItemType Directory -Path $uiRoot -Force | Out-Null
    foreach ($name in @('Progress.ps1','Unattend.ps1','Theme.ps1','theme.json','brand-logo.png')) { Copy-Item (Join-Path $DataPath $name) (Join-Path $uiRoot $name) -Force }
    $sid=[string](Get-ScheduledTask -TaskName 'AtelierPXE-Preparation' -ErrorAction SilentlyContinue).Principal.UserId
    if ($sid -notmatch '^S-1-5-') { $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    $uiAction=New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $uiRoot 'Progress.ps1')+'"')
    $uiPrincipal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'AtelierPXE-Progress' -Action $uiAction -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $sid) -Principal $uiPrincipal -Settings $taskSettings -Force | Out-Null
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
        throw "Intégrité du fichier refusée : $Path"
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
            if ($size -gt 25GB) { throw 'Archive trop volumineuse après extraction.' }
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
        if (-not $process.WaitForExit(2700000)) { throw 'Installateur encore actif après 45 minutes : consultez le processus avant toute reprise.' }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

try {
    # Cette tâche est indépendante d’OOBE. Attendre Explorer sans bloquer la connexion.
    $desktopDeadline=(Get-Date).AddSeconds(60)
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and (Get-Date) -lt $desktopDeadline) { Start-Sleep -Seconds 1 }
    Initialize-AtelierReportTrust -DataPath $DataPath
    if ($payload.deployment.cleanup_after_reporting) {
        $self=Get-Process -Id $PID
        @{pid=$PID;started=$self.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $DataPath 'preparation-worker.json') -Encoding UTF8
    }
    # Vérifier les applications demandées dans cette installation réelle de Windows.
    # Les WIM capturés et les reprises peuvent contenir d’anciens résultats de réussite.
    Set-Progress 'running' 5 'Démarrage de la préparation du poste...'
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powerShell -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $DataPath 'Progress.ps1') + '"') | Out-Null
    if ($payload.deployment.automatic_windows_update) {
        Set-Progress 'running' 10 'Windows Update en premier. Les logiciels et HPIA attendent la fin des mises à jour et des redémarrages.'
        . (Join-Path $DataPath 'WindowsUpdate-First.ps1') -DataPath $DataPath
        if (-not (Wait-AtelierWindowsUpdateFirst -DataPath $DataPath)) { return }
    }
    Write-Trace 'Début de la personnalisation du premier compte administrateur.'
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
        if (-not [AtelierWallpaper]::SystemParametersInfo(20,0,$wallpaper,3)) { throw 'Impossible de rafraîchir le fond d''écran.' }
        Write-Trace 'Fond d''écran applique.'
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
            Write-Trace ('Logiciel déjà préparé et vérifié : ' + $application.name)
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
            if (-not $executable.StartsWith(([IO.Path]::GetFullPath($folder).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Point d''entrée hors du bundle.' }
        }
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw ("Installateur absent : " + $application.name) }
        $signature = Get-AuthenticodeSignature -LiteralPath $executable
        if ($signature.Status -ne 'Valid') { throw ("Signature éditeur invalide : " + $application.name) }
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
        if ($exitCode -notin @(0,3010)) { throw ("Échec de " + $application.name + " (code $exitCode)") }
        if ($exitCode -eq 3010) { $restartNeeded = $true }
        $entry=@{id=$application.id;sha256=$asset.sha256;name=$application.name;version=$application.version;status='completed';exit_code=$exitCode}
        $results.Add($entry); $checkpoints[$application.id]=$entry
        Write-AtelierVerifiedUtf8File -Path $checkpointPath -Content (ConvertTo-Json -InputObject @($checkpoints.Values) -Depth 6) -NoBackup | Out-Null
        Write-Trace ("Logiciel prépare : " + $application.name)
    }
    Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'ready-tools.json') -Content (ConvertTo-Json -InputObject @($readyTools.ToArray()) -Depth 4) -NoBackup | Out-Null
    Stop-AtelierTiming $DataPath $toolsTiming
    Sync-AtelierTimings $DataPath
    Set-Progress 'running' 65 'Création du dossier C:\IQ_ et des diagnostics...'
    & (Join-Path $DataPath 'Prepare-IQTools.ps1') -DataPath $DataPath
    # Exporter une seule fois à la fin, après les logiciels et pilotes, sans doubler le relevé CIM.
    $script:softwareSummary=Get-AtelierSoftwareSummary -Packages $clientPackages -Results @($results.ToArray())
    $softwareStatus=if (@($results | Where-Object { $_.status -eq 'failed' }).Count) { 'needs_attention' } else { $script:softwareSummary.status }
    @{status='completed';software_status=$softwareStatus;software_summary=$script:softwareSummary;deployment_id=[string]$payload.deployment.id;timestamp=(Get-Date).ToString('o'); restart_needed=$restartNeeded; applications=@($results.ToArray())} | ConvertTo-Json -Depth 8 | Set-Content $resultPath -Encoding UTF8
    Start-Maintenance
    Write-Trace 'Personnalisation terminée. Consultez result.json pour les logiciels et le redémarrage éventuel.'
} catch {
    if ($softwareTiming) { Stop-AtelierTiming $DataPath $softwareTiming 'failed' }
    if ($toolsTiming) { Stop-AtelierTiming $DataPath $toolsTiming 'failed' }
    Sync-AtelierTimings $DataPath
    @{status='failed'; timestamp=(Get-Date).ToString('o'); message=$_.Exception.Message; applications=@($results.ToArray())} | ConvertTo-Json -Depth 6 | Set-Content $resultPath -Encoding UTF8
    Set-Progress 'failed' 0 ('Préparation interrompue : ' + $_.Exception.Message)
    . (Join-Path $DataPath 'Updates.ps1')
    if ($payload.settings.unattended) { Disable-AtelierAutoLogon }
    Complete-AtelierReport $DataPath
    Write-Trace ('Échec : ' + $_.Exception.Message)
    throw
}
