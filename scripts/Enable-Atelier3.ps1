#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
. (Join-Path $PSScriptRoot 'Unattend.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$path=Join-Path $InstallPath 'data-runtime.json'
$config=Get-Content $path -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $config.internal_mode) { throw 'Activer préalablement le mode interne de cet atelier avec Enable-InternalMode.ps1.' }
if (-not (Test-Path (Join-Path $config.data_dir 'internal-share.json'))) { throw 'Connexion SMB interne absente : configurer Enable-InternalMode.ps1.' }
foreach ($name in @('auto_enroll','client_software','automatic_windows')) { $config | Add-Member NoteProperty $name $true -Force }
Stop-ScheduledTask -TaskName 'AtelierPXE-Console'
$deadline=(Get-Date).AddSeconds(20)
while ((Get-ScheduledTask -TaskName 'AtelierPXE-Console').State -eq 'Running') {
    if ((Get-Date) -gt $deadline) { throw 'La console ne s''arrête pas ; configuration inchangee.' }
    Start-Sleep -Milliseconds 250
}
$runtime=Join-Path $InstallPath '.venv\Scripts\python.exe'
$activeCheck=@'
import sqlite3,sys
from pathlib import Path
with sqlite3.connect(Path(sys.argv[1]).resolve().as_uri()+"?mode=ro",uri=True) as con:
    print(con.execute("SELECT COUNT(*) FROM software_jobs WHERE status IN ('queued','running')").fetchone()[0])
'@
$active=$activeCheck | & $runtime - (Join-Path $config.data_dir 'deployment.sqlite3')
if ($LASTEXITCODE -ne 0 -or [int]$active -gt 0) {
    Start-ScheduledTask -TaskName 'AtelierPXE-Console'
    throw 'Une synchronisation serveur est activé ou son contrôle a échoué ; configuration inchangee. Réessayer après sa fin.'
}
$oldAgent=Get-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' -ErrorAction SilentlyContinue
if ($oldAgent) {
    Stop-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync'
    Disable-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' | Out-Null
}
Write-AtelierVerifiedUtf8File -Path $path -Content ($config | ConvertTo-Json -Depth 8) | Out-Null
Start-ScheduledTask -TaskName 'AtelierPXE-Console'
$deadline=(Get-Date).AddSeconds(25)
do {
    try { $options=Invoke-RestMethod ('http://127.0.0.1:' + $config.port + '/api/session') -TimeoutSec 2 } catch { $options=$null }
    if ($options.auto_enroll -and $options.client_software) {
        Write-Host 'ATELIER-4 : arrivée WinPE automatique, logiciels silencieux après Windows, inventaires sur le serveur.' -ForegroundColor Green
        return
    }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
throw 'La console ne confirme pas le nouveau parcours. Consulter les sauvegardes data-runtime.json et les logs.'
