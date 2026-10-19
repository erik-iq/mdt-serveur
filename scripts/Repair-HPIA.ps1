#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath='C:\ProgramData\AtelierPXE',[string]$ToolsPath='C:\IQ_')
$ErrorActionPreference='Stop'
if ([string](Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15).Manufacturer -notmatch '(?i)^(HP|Hewlett[ -]Packard)(\b|\s)') { throw 'Executer cet outil sur le PC HP deploye, pas sur le serveur PXE.' }
$resultPath=Join-Path $DataPath 'result.json'
if (-not (Test-Path $resultPath)) { throw 'Preparation Atelier absente. Utiliser le nouveau WinPE pour un nouveau deploiement.' }
$customization=Get-Content $resultPath -Encoding UTF8 -Raw | ConvertFrom-Json
if ($customization.status -ne 'completed') { throw 'Attendre la fin de la preparation Atelier avant la reparation HP.' }
foreach ($taskName in @('AtelierPXE-Preparation','AtelierPXE-Maintenance')) {
    if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -eq 'Running') { throw 'Une preparation Atelier est encore active. Attendre sa fin avant la reparation HP.' }
}
if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)^(HPImageAssistant|HpFirmwareUpdRec.*|HPBIOSUPDREC.*|HPBIOSUpdate.*)$' }).Count) { throw 'HPIA ou un flash HP est encore actif. Aucun processus interrompu ; attendre sa fin.' }
$files=@('Client-Software.ps1','Install-WinGet.ps1','software-sources.json','HP-ImageAssistant.ps1','Reporting.ps1','Timings.ps1','New-DeploymentReport.ps1','Maintenance.ps1','Updates.ps1','IQ-Paths.ps1')
foreach ($name in $files) { if (-not (Test-Path (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw ('Archive incomplete : '+$name+' absent.') } }
$mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-Maintenance')
$owned=$mutex.WaitOne(0)
if (-not $owned) { $mutex.Dispose();throw 'Finalisation Atelier encore active. Reessayer apres sa fin.' }
try {
    $backup=Join-Path $DataPath ('repair-backups\hpia-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in @('result.json','hpia-result.json','ready-tools.json','maintenance.json')) {
        $path=Join-Path $DataPath $name
        if (Test-Path $path) { Copy-Item -LiteralPath $path -Destination $backup }
    }
    foreach ($name in $files) {
        $target=Join-Path $DataPath $name
        if (Test-Path $target) { Copy-Item -LiteralPath $target -Destination $backup }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Force
    }
    . (Join-Path $DataPath 'Unattend.ps1')
    . (Join-Path $DataPath 'Client-Software.ps1')
    . (Join-Path $DataPath 'Reporting.ps1')
    . (Join-Path $DataPath 'HP-ImageAssistant.ps1')
    Initialize-AtelierReportTrust $DataPath
    $entry=@(Install-AtelierClientSoftware -DataPath $DataPath -Packages @('hpia') -OnProgress {param($Percent,$Message);Write-Host $Message}) | Select-Object -First 1
    if (-not $entry -or $entry.status -ne 'completed' -or -not $entry.tool) { throw ('Installation HPIA non verifiee : '+[string]$entry.reason) }
    $toolsPathJson=Join-Path $DataPath 'ready-tools.json'
    $tools=@()
    if (Test-Path $toolsPathJson) { $tools=@(Get-Content $toolsPathJson -Encoding UTF8 -Raw | ConvertFrom-Json | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ine 'HPImageAssistant.exe' }) }
    $tools+=@($entry.tool)
    Write-AtelierVerifiedUtf8File -Path $toolsPathJson -Content (ConvertTo-Json -InputObject $tools -Depth 6) -NoBackup | Out-Null
    $apps=@($customization.applications | Where-Object { $_ -and $_.id -ne 'hpia' -and $_.name -notmatch '(?i)^HP\s*Image\s*Assistant$' })
    $apps+=@($entry)
    $customization | Add-Member NoteProperty applications $apps -Force
    $customization | Add-Member NoteProperty software_status $(if (@($apps | Where-Object { $_.status -eq 'failed' }).Count) { 'needs_attention' } else { 'completed' }) -Force
    Write-AtelierVerifiedUtf8File -Path $resultPath -Content ($customization | ConvertTo-Json -Depth 8) -NoBackup | Out-Null
    $hpPath=Join-Path $DataPath 'hpia-result.json'
    if (Test-Path $hpPath) { Remove-Item -LiteralPath $hpPath -Force }
    $hp=Invoke-AtelierHpia -DataPath $DataPath -ToolsPath $ToolsPath -OnProgress {param($Message);Write-Host $Message}
    $oldMaintenancePath=Join-Path $DataPath 'maintenance.json'
    $restart=[bool]$customization.restart_needed -or [bool]$hp.reboot_required
    if (Test-Path $oldMaintenancePath) {
        $old=Get-Content $oldMaintenancePath -Encoding UTF8 -Raw | ConvertFrom-Json
        $restart=$restart -or [bool]$old.reboot_required
    }
    $status=if ($hp.status -eq 'completed' -and $customization.software_status -eq 'completed' -and -not $restart) { 'completed' } else { 'needs_attention' }
    $state=@{status=$status;attempts=1;passes=0;reboots=0;hpia=$hp;reboot_required=$restart;timestamp=[DateTime]::UtcNow.ToString('o');message=[string]$hp.message;windows=@{status='manual';message='Windows Update a lancer manuellement'};store=@{status='manual';message='Microsoft Store a lancer manuellement'}}
    Write-AtelierVerifiedUtf8File -Path $oldMaintenancePath -Content ($state | ConvertTo-Json -Depth 8) -NoBackup | Out-Null
    & (Join-Path $DataPath 'New-DeploymentReport.ps1') -DataPath $DataPath -OutputDirectory $ToolsPath -RefreshInventory
    Write-Host $hp.message
    if ($restart) { Write-Host 'Redemarrage manuel necessaire. Atelier ne lance aucun redemarrage.' }
    Write-Host ('Rapports HP : '+(Join-Path $ToolsPath 'Rapports\HPImageAssistant'))
} finally { $mutex.ReleaseMutex();$mutex.Dispose() }
