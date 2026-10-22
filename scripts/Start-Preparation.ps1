#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$DataPath='C:\ProgramData\AtelierPXE')
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
# FirstLogonCommands doit rendre la main rapidement. Le planificateur gère les tâches longues.
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action=New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $DataPath 'FirstLogon.ps1') + '"')
$principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
$triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $sid),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)))
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'AtelierPXE-Preparation' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
