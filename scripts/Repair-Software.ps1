#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath='C:\ProgramData\AtelierPXE',[string]$ToolsPath='C:\IQ_')
$ErrorActionPreference='Stop'
$payloadPath=Join-Path $DataPath 'personalization.json'
if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw 'Executer cette reparation sur le PC Windows deploye, pas sur le serveur PXE.' }
$payload=Get-Content -LiteralPath $payloadPath -Encoding UTF8 -Raw | ConvertFrom-Json
if ($payload.settings.software_mode -ne 'winget') { throw 'Ce poste ne contient pas une selection WinGet. Collecter personalization.json avant de poursuivre.' }
foreach ($taskName in @('AtelierPXE-Preparation','AtelierPXE-Maintenance')) {
    if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -eq 'Running') { throw 'Preparation Atelier encore active. Attendre sa fin avant la reparation.' }
}
if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)^(winget|HPImageAssistant|HpFirmwareUpdRec.*|HPBIOSUPDREC.*|HPBIOSUpdate.*)$' }).Count) { throw 'Installateur ou traitement HP encore actif. Attendre sa fin ; aucun processus interrompu.' }
$files=@('Client-Software.ps1','Install-WinGet.ps1','software-sources.json','FirstLogon.ps1','Maintenance.ps1','New-DeploymentReport.ps1','Reporting.ps1','HP-ImageAssistant.ps1','Updates.ps1','Unattend.ps1','Timings.ps1','IQ-Paths.ps1')
foreach ($name in $files) { if (-not (Test-Path (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw ('Archive incomplete : '+$name) } }
$mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-Maintenance')
$owned=$mutex.WaitOne(0)
if (-not $owned) { $mutex.Dispose();throw 'Finalisation Atelier active. Reessayer apres sa fin.' }
try {
    $backup=Join-Path $DataPath ('repair-backups\software-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in @($files+@('result.json','maintenance.json','winget-client-state.json','ready-tools.json','inventory-finalized.json'))) {
        $path=Join-Path $DataPath $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup }
    }
    foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $DataPath $name) -Force }
    . (Join-Path $DataPath 'Unattend.ps1')
    . (Join-Path $DataPath 'Client-Software.ps1')
    . (Join-Path $DataPath 'Reporting.ps1')
    Initialize-AtelierReportTrust $DataPath
    $packages=@($payload.settings.winget_packages)
    Write-Host ('Logiciels demandes : '+($packages -join ', '))
    $results=@(Install-AtelierClientSoftware -DataPath $DataPath -Packages $packages -OnProgress {
        param($Percent,$Message)
        Write-Host $Message
        Send-AtelierWindowsProgress $DataPath 'running' $Percent $Message
    })
    $summary=Get-AtelierSoftwareSummary -Packages $packages -Results $results
    $resultPath=Join-Path $DataPath 'result.json'
    $previous=if (Test-Path $resultPath) { Get-Content $resultPath -Encoding UTF8 -Raw | ConvertFrom-Json } else { $null }
    $restart=[bool]$previous.restart_needed -or [bool](@($results | Where-Object { $_.exit_code -in @(3010,1641) }).Count)
    $result=@{status='completed';software_status=$summary.status;software_summary=$summary;deployment_id=[string]$payload.deployment.id;timestamp=[DateTime]::UtcNow.ToString('o');restart_needed=$restart;applications=$results}
    Write-AtelierVerifiedUtf8File -Path $resultPath -Content ($result | ConvertTo-Json -Depth 8) -NoBackup | Out-Null
    $hp=@($results | Where-Object { $_.id -eq 'hpia' -and $_.status -eq 'completed' -and $_.tool } | ForEach-Object { $_.tool })
    Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'ready-tools.json') -Content (ConvertTo-Json -InputObject $hp -Depth 6) -NoBackup | Out-Null
    # Re-evaluate final status; keep any durable HP result to avoid rerunning a flash.
    foreach ($name in @('maintenance.json','inventory-finalized.json')) {
        $path=Join-Path $DataPath $name
        if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    }
    foreach ($entry in $results) { Write-Host ($entry.name+' : '+$entry.status+' / '+$entry.reason) }
} finally { $mutex.ReleaseMutex();$mutex.Dispose() }
& (Join-Path $DataPath 'Maintenance.ps1') -DataPath $DataPath -ToolsPath $ToolsPath
if ($summary.status -ne 'completed') { throw ('Logiciels non verifies : '+($summary.missing -join ', ')+'. Consulter '+(Join-Path $DataPath 'software-logs')) }
Write-Host 'Logiciels verifies. Aucun redemarrage automatique demande par Atelier.' -ForegroundColor Green
