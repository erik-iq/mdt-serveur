#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Raw | ConvertFrom-Json
$health=Invoke-RestMethod ('http://127.0.0.1:' + $config.port + '/health') -TimeoutSec 10
if ($health.revision -ne '4.0') { throw 'Mettre a jour la console avant de configurer son agent WinGet.' }
if (-not (Test-Path (Join-Path $config.data_dir 'software-sync\worker-key'))) { throw 'Cle agent absente. Verifier le demarrage de la console.' }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$existing=Get-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    if ($existing.Principal.UserId -in @($identity.User.Value,$identity.Name)) {
        Write-Host ('Agent deja actif pour ' + $identity.Name + '.') -ForegroundColor Green
        return
    }
    throw 'Agent deja demarre sous un autre compte. Pour changer de compte : arreter la tache apres la fin des mises a jour.'
}
$script=Join-Path $InstallPath 'scripts\Software-Worker.ps1'
$action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $script + '" -InstallPath "' + $InstallPath + '"') -WorkingDirectory $InstallPath
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$principal=New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Telecharge les logiciels demandes dans Atelier PXE avec le profil WinGet de cet administrateur.' -Force | Out-Null
Start-ScheduledTask -TaskName 'AtelierPXE-SoftwareSync'
Write-Host ('Agent configure pour ' + $identity.Name + '. Garder cette session ouverte ; elle peut etre verrouillee ou deconnectee en RDP.') -ForegroundColor Green
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { Write-Warning 'WinGet absent dans cette session. Executer scripts\Install-WinGet.ps1, puis fermer et rouvrir la session Windows.' }
