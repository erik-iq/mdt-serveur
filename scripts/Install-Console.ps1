#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ServerUrl = 'https://192.168.99.2',
    [int]$Port = 8080,
    [string]$PythonExe = 'C:\Program Files\Python312\python.exe',
    [string]$DataPath = 'D:\AtelierPXE\data',
    [switch]$InstallStartupTask
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path $PythonExe)) { throw 'Installez Python 3.12 pour tous les utilisateurs, ou précisez -PythonExe.' }
& $PythonExe -c 'import sys; assert sys.version_info[:2] == (3,12), "Python 3.12 requis"'
if ($LASTEXITCODE -ne 0) { throw 'Version Python incompatible.' }
if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Port invalide.' }
$uri = [Uri]$ServerUrl
if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'Une origine HTTPS sans chemin est requise.' }
New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
$venv = Join-Path $root '.venv'
if (-not (Test-Path $venv)) { & $PythonExe -m venv $venv; if ($LASTEXITCODE -ne 0) { throw 'Échec de création du venv.' } }
$runtime = Join-Path $venv 'Scripts\python.exe'
& $runtime -m pip install -c (Join-Path $root 'constraints.txt') -r (Join-Path $root 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Échec d''installation des dépendances.' }
$configPath = Join-Path $root 'data-runtime.json'
if (Test-Path $configPath) { throw 'data-runtime.json existe déjà : vérifiez son contenu sans l''écraser.' }
@{base_url=$ServerUrl.TrimEnd('/'); data_dir=$DataPath; port=$Port} | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
# Bootstrap the database and random token as the administrator, before restricting its ACL.
$env:MDT_DATA_DIR = $DataPath
$env:MDT_BASE_URL = $ServerUrl.TrimEnd('/')
Push-Location $root
try { & $runtime -c 'from app.main import create_app; create_app()'; if ($LASTEXITCODE -ne 0) { throw 'Échec de l''initialisation.' } } finally { Pop-Location }
& icacls.exe $DataPath /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-19:(OI)(CI)M'
if ($LASTEXITCODE -ne 0) { throw 'Échec des permissions du dossier de données.' }
if ($InstallStartupTask) {
    if (Get-ScheduledTask -TaskName 'AtelierPXE-Console' -ErrorAction SilentlyContinue) { throw 'La tâche existe déjà. Examinez-la avant toute modification.' }
    & icacls.exe $root /grant '*S-1-5-19:(OI)(CI)RX'
    if ($LASTEXITCODE -ne 0) { throw 'Échec des droits de lecture pour LOCAL SERVICE.' }
    $action = New-ScheduledTaskAction -Execute $runtime -Argument ('"' + (Join-Path $root 'scripts\serve.py') + '"') -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskName 'AtelierPXE-Console' -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName 'AtelierPXE-Console'
}
Write-Host 'Console installée. Le serveur Python écoute uniquement sur 127.0.0.1 ; configurez le proxy HTTPS IIS avant l''accès réseau.'
Write-Host "Jeton administrateur : fichier $DataPath\admin-token (ne pas diffuser)."
