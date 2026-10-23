#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [string]$InstallPath,
    [string]$BackupPath = ('D:\AtelierPXE\backups\console-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation -InstallPath $InstallPath
$source = (Resolve-Path -LiteralPath $SourcePath).ProviderPath.TrimEnd('\')
$installed = (Resolve-Path -LiteralPath $InstallPath).ProviderPath.TrimEnd('\')
$backup = [IO.Path]::GetFullPath($BackupPath).TrimEnd('\')
if ($source -eq $installed -or $source.StartsWith($installed + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Extrayez la nouvelle version dans un dossier distinct de la console installée.'
}
foreach ($base in @($source,$installed)) {
    if ($backup -eq $base -or $backup.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Placez la sauvegarde hors des dossiers source et installation.'
    }
}
if (Test-Path -LiteralPath $backup) { throw 'Le dossier de sauvegarde existe déjà. Choisissez un nouveau chemin.' }
$files = @('README.md','.gitignore','.env.example','requirements.txt','requirements-dev.txt','requirements-browser.txt','constraints.txt')
$folders = @('app','scripts','docs','tests')
foreach ($name in @('Update-WindowsImage.ps1','Enable-WindowsImageMaintenance.ps1','Windows-ImageServicing.ps1','windows_update_catalog.py','windows_image_profiles.py')) {
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $source 'scripts') $name))) { throw ('Archive incomplète : scripts\'+$name+' absent.') }
}
foreach ($name in @('scripts\WinPE-IntelDrivers.ps1','scripts\WinPE-NetworkRecovery.ps1','app\identity.py','app\hp_repository.py','scripts\Enable-HPRepository.ps1','scripts\HP-RepositoryWorker.ps1','scripts\HP-ClientRepository.ps1','scripts\HP-Reports.ps1','scripts\HP-Repository.ps1','scripts\Finalization.ps1','scripts\HP-ImageAssistant.ps1','app\computers.py','scripts\Timings.ps1','scripts\Set-AtelierDefaults.ps1','scripts\Upgrade-Atelier4.ps1','scripts\Start-Preparation.ps1','scripts\IQ-Paths.ps1','scripts\Theme.ps1','scripts\brand-logo.png','scripts\theme.json','scripts\Clear-AtelierObsolete.ps1','app\main.py','app\inventories.py','scripts\Client-Software.ps1','scripts\Inventory-Transfer.ps1','scripts\Upgrade-Atelier3.ps1','scripts\Enable-Atelier3.ps1','scripts\Remove-OldAtelierWinPE.ps1','app\software_jobs.py','scripts\Enable-SoftwareSync.ps1','scripts\Software-Worker.ps1','scripts\Console-Installation.ps1','scripts\Export-Inventaire.ps1','scripts\Sync-Applications.ps1','scripts\software-sources.json','app\reports.py','scripts\Reporting.ps1','scripts\New-DeploymentReport.ps1','scripts\Test-Materiel.ps1','scripts\Tests-Materiel.html','scripts\Verifier-Garantie.ps1','scripts\serve.py','scripts\Wizard.ps1','scripts\FirstLogon.ps1','scripts\Unattend.ps1','scripts\WinPE-Session.ps1','scripts\Partitions.ps1','scripts\atelier.cmd') + $files + $folders) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) { throw "Archive incomplète : $name absent." }
}
$configPath = Join-Path $installed 'data-runtime.json'
$config = Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw | ConvertFrom-Json
$database = Join-Path $config.data_dir 'deployment.sqlite3'
$runtime = Join-Path $installed '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $database) -or -not (Test-Path -LiteralPath $runtime)) { throw 'Installation existante incomplète : base SQLite ou Python absent.' }
$task = Get-ScheduledTask -TaskName 'AtelierPXE-Console'
if ($task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ne $runtime -or $task.Actions[0].Arguments -notlike ('*' + (Join-Path $installed 'scripts\serve.py') + '*')) {
    throw 'La tâche AtelierPXE-Console ne correspond pas a ce dossier. Vérifiez son action avant la mise à jour.'
}
$activeCheck = @'
import sqlite3, sys
from pathlib import Path
with sqlite3.connect(Path(sys.argv[1]).resolve().as_uri() + "?mode=ro", uri=True) as connection:
    columns = {row[1] for row in connection.execute("PRAGMA table_info(deployments)")}
    query = "SELECT COUNT(*) FROM deployments WHERE status='running'"
    if "windows_status" in columns:
        query += " OR windows_status IN ('running','reboot_pending','retry_pending')"
    active = connection.execute(query).fetchone()[0]
    if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='software_jobs'").fetchone():
        active += connection.execute("SELECT COUNT(*) FROM software_jobs WHERE status IN ('queued','running')").fetchone()[0]
    print(active)
'@
$active = $activeCheck | & $runtime - $database
if ($LASTEXITCODE -ne 0) { throw 'Impossible de contrôler les déploiements actifs.' }
if ([int]$active -gt 0) { throw 'Un déploiement ou une synchronisation logicielle est en cours. Attendez sa fin avant de mettre à jour la console.' }
if (-not $PSCmdlet.ShouldProcess($installed, 'Sauvegarder la console et SQLite, puis installer la nouvelle version')) { return }
New-Item -ItemType Directory -Path $backup | Out-Null
& icacls.exe $backup /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Impossible de protéger la sauvegarde. Mise à jour arrêtée.' }
$stopped = $false
$updated = $false
$softwareTask = Get-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' -ErrorAction SilentlyContinue
$softwareWasRunning = $softwareTask -and $softwareTask.State -eq 'Running'
$hpTask = Get-ScheduledTask -TaskName 'AtelierPXE-HpRepository' -ErrorAction SilentlyContinue
$hpWasRunning = $hpTask -and $hpTask.State -eq 'Running'
$imageMaintenanceLock=$null
try {
    $maintenanceRoot=Join-Path $config.data_dir 'windows-servicing'
    if (Test-Path -LiteralPath $maintenanceRoot -PathType Container) {
        # Une opération DISM active doit finir avant le remplacement de ses scripts.
        $imageMaintenanceLock=[IO.File]::Open((Join-Path $maintenanceRoot 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }
    Stop-ScheduledTask -TaskName 'AtelierPXE-Console'
    $stopped = $true
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-ScheduledTask -TaskName 'AtelierPXE-Console').State -eq 'Running') {
        if ((Get-Date) -gt $deadline) { throw 'La tâche ne s''arrête pas. Aucun fichier remplace.' }
        Start-Sleep -Milliseconds 250
    }
    # Recontrôler après l’arrêt HTTP, pour empêcher une demande concurrente pendant le remplacement.
    $active = $activeCheck | & $runtime - $database
    if ($LASTEXITCODE -ne 0 -or [int]$active -gt 0) {
        Start-ScheduledTask -TaskName 'AtelierPXE-Console'
        $stopped = $false
        throw 'Une opération a démarré pendant la préparation. Aucun fichier remplace ; réessayer après sa fin.'
    }
    if ($softwareWasRunning) { Stop-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' }
    if ($hpWasRunning) { Stop-ScheduledTask -TaskName 'AtelierPXE-HpRepository' }
    $sourceBackup = New-Item -ItemType Directory -Path (Join-Path $backup 'console')
    foreach ($name in $files + $folders + @('data-runtime.json','.env')) {
        $path = Join-Path $installed $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $sourceBackup.FullName -Recurse }
    }
    # La sauvegarde SQLite inclut les données WAL validées ; aucun jeton n’est copié.
    $databaseBackup = Join-Path $backup 'deployment.sqlite3'
    & $runtime -c 'import sqlite3,sys; source=sqlite3.connect(sys.argv[1]); target=sqlite3.connect(sys.argv[2]); source.backup(target); target.close(); source.close()' $database $databaseBackup
    if ($LASTEXITCODE -ne 0) { throw 'Sauvegarde SQLite impossible. Aucun fichier remplace.' }
    $dependenciesChanged = $false
    foreach ($name in @('requirements.txt','constraints.txt')) {
        if ((Get-FileHash (Join-Path $source $name)).Hash -ne (Get-FileHash (Join-Path $installed $name)).Hash) { $dependenciesChanged = $true }
    }
    foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $installed $name) -Force }
    foreach ($name in $folders) {
        $target = Join-Path $installed $name
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $source $name) -Force | Copy-Item -Destination $target -Recurse -Force
    }
    if ($dependenciesChanged) {
        & $runtime -m pip install -c (Join-Path $installed 'constraints.txt') -r (Join-Path $installed 'requirements.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Échec de mise à jour des dépendances.' }
    }
    & icacls.exe $installed /grant '*S-1-5-19:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Impossible de vérifier la lecture par LOCAL SERVICE.' }
    Start-ScheduledTask -TaskName 'AtelierPXE-Console'
    $health = $null
    $deadline = (Get-Date).AddSeconds(20)
    do {
        try { $health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $config.port + '/health') -TimeoutSec 2 } catch { $health = $null }
        if ($health.status -eq 'ok' -and $health.version -eq '0.2.0' -and $health.release -eq 'ATELIER-2' -and $health.revision -eq '4.0' -and $health.ui_revision -eq 'IQ-6.0') { $updated = $true; break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if (-not $updated) { throw 'La console 0.2.0 ne repond pas. Consultez data\logs\console.log et la sauvegarde.' }
    Write-Host ('Console 0.2.0 disponible : ' + $config.base_url) -ForegroundColor Green
    Write-Host "Sauvegarde privée : $backup"
    if ($softwareWasRunning) { Start-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' }
    if ($hpWasRunning) { Start-ScheduledTask -TaskName 'AtelierPXE-HpRepository' }
    Write-Host 'Pour les changements de scripts clients, reconstruire WinPE avec Upgrade-Atelier4.ps1. La maintenance WIM seule ne le nécessite pas.'
} catch {
    if ($stopped -and -not $updated) {
        Stop-ScheduledTask -TaskName 'AtelierPXE-Console' -ErrorAction SilentlyContinue
        Write-Warning "Console arrêtée pour diagnostic. Sauvegarde : $backup. Procédure de reprise : docs\ASSISTANT-PXE.md."
    }
    throw
} finally {
    if ($imageMaintenanceLock) { $imageMaintenanceLock.Dispose() }
}
