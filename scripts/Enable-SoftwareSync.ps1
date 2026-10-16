#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Raw | ConvertFrom-Json
$health=Invoke-RestMethod ('http://127.0.0.1:' + $config.port + '/health') -TimeoutSec 10
if ($health.revision -ne '3.0') { throw 'Mettre à jour la console avant de configurer son agent WinGet.' }
if (-not (Test-Path (Join-Path $config.data_dir 'software-sync\worker-key'))) { throw 'Clé agent absente. Vérifier le démarrage de la console.' }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$existing=Get-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    if ($existing.Principal.UserId -in @($identity.User.Value,$identity.Name)) {
        Write-Host ('Agent déjà actif pour ' + $identity.Name + '.') -ForegroundColor Green
        return
    }
    throw 'Agent déjà démarré sous un autre compte. Pour changer de compte : arrêter la tâche après la fin des mises à jour.'
}
$script=Join-Path $InstallPath 'scripts\Software-Worker.ps1'
$action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $script + '" -InstallPath "' + $InstallPath + '"') -WorkingDirectory $InstallPath
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$principal=New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Télécharge les logiciels demandés dans Atelier PXE avec le profil WinGet de cet administrateur.' -Force | Out-Null
Start-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync'
Write-Host ('Agent configuré pour ' + $identity.Name + '. Garder cette session ouverte ; elle peut être verrouillée ou déconnectée en RDP.') -ForegroundColor Green
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { Write-Warning 'WinGet absent dans cette session. Exécuter scripts\Install-WinGet.ps1, puis fermer et rouvrir la session Windows.' }
