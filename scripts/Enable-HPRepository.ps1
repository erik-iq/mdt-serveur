#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$InstallPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$directory=Join-Path $config.data_dir 'hp-repository'
if (-not (Test-Path (Join-Path $directory 'worker-key'))) { throw 'Mettre la console a jour avant de configurer CMSL.' }
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
# Install the HP library once on the acquisition machine, never on deployed PCs.
try {
    $moduleRoot=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')).TrimEnd('\')+'\'
    if (-not (Get-Module -ListAvailable HPCMSL | Where-Object { $_.Version -ge [version]'1.9.0' -and $_.ModuleBase.StartsWith($moduleRoot,[StringComparison]::OrdinalIgnoreCase) })) {
        Write-Host 'Installation de la bibliotheque officielle HP CMSL sur le serveur...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force -Confirm:$false | Out-Null
        Install-Module -Name HPCMSL -RequiredVersion '1.9.0' -Repository PSGallery -Scope AllUsers -AcceptLicense -Force -AllowClobber -Confirm:$false
    }
    Import-Module HPCMSL -MinimumVersion '1.9.0' -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'HP-Repository.ps1')
    foreach ($name in @('Initialize-HPRepository','Set-HPRepositoryConfiguration','Add-HPRepositoryFilter','Invoke-HPRepositorySync','Invoke-HPRepositoryCleanup')) { Get-AtelierHpCmslCommand $name | Out-Null }
} catch {
    Add-Content -LiteralPath (Join-Path $directory 'setup.log') -Value ($_.Exception.Message) -Encoding UTF8
    Write-Warning 'CMSL non disponible. Le depot reste en attente ; HPIA pourra utiliser Internet. Consulter hp-repository\setup.log sur .250.'
}
$task=Get-ScheduledTask -TaskName 'AtelierPXE-HpRepository' -ErrorAction SilentlyContinue
if ($task -and $task.State -eq 'Running') { Write-Host 'Agent CMSL deja actif.';return }
$action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "'+(Join-Path $InstallPath 'scripts\HP-RepositoryWorker.ps1')+'" -InstallPath "'+$InstallPath+'"') -WorkingDirectory $InstallPath
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName 'AtelierPXE-HpRepository' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Description 'Alimente le depot local de SoftPaq HP avec CMSL sans installer de pilote sur le serveur.' -Force | Out-Null
Start-ScheduledTask -TaskName 'AtelierPXE-HpRepository'
Write-Host 'Depot HP configure. Les demandes des postes alimentent automatiquement le cache de .250.'
