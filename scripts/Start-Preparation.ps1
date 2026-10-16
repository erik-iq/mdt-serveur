#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$DataPath='C:\ProgramData\AtelierPXE')
$ErrorActionPreference='Stop'
# FirstLogonCommands must return promptly. Task Scheduler owns the long work.
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action=New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $DataPath 'FirstLogon.ps1') + '"')
$principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
$triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $sid),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)))
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'AtelierPXE-Preparation' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
