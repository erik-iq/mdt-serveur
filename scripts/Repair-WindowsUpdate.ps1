#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath='C:\ProgramData\AtelierPXE',[string]$ToolsPath='C:\IQ_')

$ErrorActionPreference='Stop'
$payloadPath=Join-Path $DataPath 'personalization.json'
if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw 'Lancer ce script sur le poste Windows déployé, pas sur le serveur PXE.' }
if ((Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15).ProductType -ne 1) { throw 'La réparation est réservée au poste client Windows.' }
$payload=Get-Content -LiteralPath $payloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $payload.deployment.automatic_windows_update) { throw 'Le déploiement ne demande pas Windows Update automatique. Réparation non appliquée.' }
$files=@('Unattend.ps1','WindowsUpdate-First.ps1','Client-WindowsUpdate.ps1','WindowsUpdate-Diagnostic.ps1','WindowsUpdate-InstallTest.ps1','FirstLogon.ps1','Maintenance.ps1','Progress.ps1','Reporting.ps1','New-DeploymentReport.ps1')
foreach ($name in $files) {
    $source=Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Archive incomplète : '+$name) }
    $errors=$null;$tokens=$null
    [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw ('Syntaxe du fichier refusée : '+$name) }
    if ([IO.Path]::GetFullPath($source) -eq [IO.Path]::GetFullPath((Join-Path $DataPath $name))) { throw 'Extraire le correctif hors du dossier privé Atelier avant la réparation.' }
}
$taskNames=@('AtelierPXE-Preparation','AtelierPXE-Maintenance','AtelierPXE-WindowsUpdateFirst')
$tasks=@($taskNames | ForEach-Object {Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue})
if (@($tasks | Where-Object {$_.State -eq 'Running'}).Count) { throw 'Une préparation Atelier est encore active. Attendre sa fin puis relancer ce même script ; aucun processus ne sera interrompu.' }
$session=New-Object -ComObject Microsoft.Update.Session
$installer=$session.CreateUpdateInstaller()
try { if ($installer.IsBusy) { throw 'Windows installe encore une mise à jour. Attendre sa fin puis relancer ce script ; aucun installateur ne sera interrompu.' } }
finally {
    if ([Runtime.InteropServices.Marshal]::IsComObject($installer)) {[void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)}
    if ([Runtime.InteropServices.Marshal]::IsComObject($session)) {[void][Runtime.InteropServices.Marshal]::ReleaseComObject($session)}
}
$enabled=@($tasks | Where-Object {$_.State -ne 'Disabled'} | ForEach-Object {$_.TaskName})
$locks=New-Object 'Collections.Generic.List[object]'
$success=$false
try {
    foreach ($name in $enabled) { Disable-ScheduledTask -TaskName $name | Out-Null }
    # Les tâches ont été gelées ; contrôler aussi les processus lancés juste avant ce gel.
    $active=@(Get-CimInstance Win32_Process -OperationTimeoutSec 15 | Where-Object {
        $_.Name -match '^(powershell|pwsh)\.exe$' -and $_.CommandLine -and
        ($_.CommandLine.IndexOf($DataPath,[StringComparison]::OrdinalIgnoreCase) -ge 0) -and
        $_.CommandLine -match '(?i)(FirstLogon|Maintenance|WindowsUpdate-First)\.ps1'
    })
    if ($active.Count) { throw 'Un traitement Atelier est encore actif. Attendre sa fin puis relancer ce script.' }
    foreach ($name in @('Global\AtelierPXE-Maintenance','Global\AtelierPXE-WindowsUpdateFirst')) {
        $mutex=New-Object Threading.Mutex($false,$name)
        if (-not $mutex.WaitOne(0)) { $mutex.Dispose();throw 'Un traitement de préparation détient encore le verrou. Attendre sa fin.' }
        $locks.Add($mutex)
    }
    $backup=Join-Path $DataPath ('repair-backups\windows-update-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in @($files+@('result.json','maintenance.json','windows-update-result.json','windows-update-first-restart.json','inventory-finalized.json'))) {
        $path=Join-Path $DataPath $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup -Force }
    }
    foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $DataPath $name) -Force }
    . (Join-Path $DataPath 'Unattend.ps1')
    $statePath=Join-Path $DataPath 'windows-update-result.json'
    if (Test-Path $statePath) {
        $state=Read-AtelierSharedUtf8File -Path $statePath | ConvertFrom-Json
        # Réouvrir la recherche sans effacer les installations, preuves ou résultats inconnus.
        if ($state.status -eq 'needs_attention') {
            $state | Add-Member NoteProperty message_before_repair $state.message -Force
            $state.status='running';$state.message='Reprise demandée après correction des accès concurrents.'
            Write-AtelierVerifiedUtf8File -Path $statePath -Content ($state | ConvertTo-Json -Depth 24) -NoBackup | Out-Null
        }
    }
    foreach ($name in @('maintenance.json','inventory-finalized.json')) {
        $path=Join-Path $DataPath $name
        if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    }
    $ui=Join-Path $ToolsPath 'Rapports\Preparation'
    if (Test-Path $ui) {
        foreach ($name in @('Progress.ps1','Unattend.ps1')) { Copy-Item -LiteralPath (Join-Path $DataPath $name) -Destination $ui -Force }
    }
    # L’ancienne fenêtre peut être figée sur l’échec ; fermer uniquement son processus UI.
    $uiPaths=@((Join-Path $DataPath 'Progress.ps1'),(Join-Path $ui 'Progress.ps1'))
    foreach ($process in @(Get-CimInstance Win32_Process -OperationTimeoutSec 15)) {
        if ($process.Name -notmatch '^(powershell|pwsh)\.exe$' -or -not $process.CommandLine) { continue }
        foreach ($uiPath in $uiPaths) {
            if ($process.CommandLine -match ('(?i)-File\s+"?'+[regex]::Escape($uiPath)+'(?=["\s]|$)')) {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }
    # Le bureau actuel et les connexions suivantes relancent le parcours interactif habituel.
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action=New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $DataPath 'FirstLogon.ps1')+'" -DataPath "'+$DataPath+'" -ToolsPath "'+$ToolsPath+'"')
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $sid),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)))
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'AtelierPXE-Preparation' -Action $action -Principal $principal -Trigger $triggers -Settings $settings -Force | Out-Null
    # Les tâches de maintenance seront réactivées au moment prévu par FirstLogon.
    if (Get-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst' -Confirm:$false
    }
    $success=$true
    Write-Host ('Correctif installé. Sauvegarde des états : '+$backup)
} finally {
    foreach ($mutex in $locks) { $mutex.ReleaseMutex();$mutex.Dispose() }
    if (-not $success) {
        foreach ($name in $enabled) { Enable-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Out-Null }
    }
}
Start-ScheduledTask -TaskName 'AtelierPXE-Preparation'
Write-Host 'Préparation relancée : Windows Update en premier, puis logiciels et HPIA. Les redémarrages nécessaires sont automatiques.' -ForegroundColor Green
Write-Host 'Le bilan est affiché dans la fenêtre Préparation du poste et conservé dans C:\IQ_\Rapports.'
Write-Host "Le site peut conserver l’ancien échec : son état final ne sera pas réinitialisé par cette réparation locale."
