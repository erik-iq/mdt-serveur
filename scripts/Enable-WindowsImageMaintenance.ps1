#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,[switch]$RunNow)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
. (Join-Path $PSScriptRoot 'Windows-ImageServicing.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$script=Join-Path $InstallPath 'scripts\Update-WindowsImage.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw 'Mettre la console à jour avant de planifier la maintenance.' }
$config=Get-Content -LiteralPath (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$root=Assert-AtelierServicingPath (Join-Path $config.data_dir 'windows-servicing')
New-Item -ItemType Directory -Path $root -Force | Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Impossible de protéger les sauvegardes et les montages Windows.' }
$taskName='AtelierPXE-WindowsImageMaintenance'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and $task.State -eq 'Running') { throw 'La maintenance fonctionne déjà ; aucune tâche remplacée.' }
if ($task -and (@($task.Actions).Count -ne 1 -or $task.Actions[0].Arguments -notlike ('*"'+$script+'"*'))) { throw 'La tâche existante ne correspond pas a cette console.' }
$powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($script.Contains('"') -or $InstallPath.Contains('"')) { throw 'Chemin de console invalide.' }
$arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'+$script+'" -InstallPath "'+$InstallPath+'"'
$commandXml=[Security.SecurityElement]::Escape($powerShell)
$argumentsXml=[Security.SecurityElement]::Escape($arguments)
$directoryXml=[Security.SecurityElement]::Escape($InstallPath)
$next=(Get-Date -Day 15 -Hour 2 -Minute 0 -Second 0).Date.AddHours(2)
if ($next -le (Get-Date)) { $next=$next.AddMonths(1) }
$startBoundary=$next.ToString('yyyy-MM-ddTHH:mm:ss')
# Le 15 suit le deuxième mardi, y compris lorsque ce mardi tombe le 14.
# PT0S évite d’arrêter DISM en plein travail. Le verrou privé couvre aussi
# les appels manuels. Les tâches préparent seulement, sans mise en test ni publication.
# SYSTEM est identifié par son SID. ServiceAccount est une valeur de l’API,
# pas un LogonType XML valide ; omettre cet élément facultatif pour ce compte intégré.
$xml=@"
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Prépare les images Windows avec les correctifs Microsoft ; publication après test uniquement.</Description></RegistrationInfo>
  <Triggers><CalendarTrigger><StartBoundary>$startBoundary</StartBoundary><Enabled>true</Enabled><ScheduleByMonth><DaysOfMonth><Day>15</Day></DaysOfMonth><Months><January/><February/><March/><April/><May/><June/><July/><August/><September/><October/><November/><December/></Months></ScheduleByMonth></CalendarTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable><Enabled>true</Enabled><ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings>
  <Actions Context="Author"><Exec><Command>$commandXml</Command><Arguments>$argumentsXml</Arguments><WorkingDirectory>$directoryXml</WorkingDirectory></Exec></Actions>
</Task>
"@
Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
if ($RunNow) { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop }
Write-Host 'Maintenance Windows planifiée le 15 de chaque mois à 02:00. Aucune publication automatique.'
Write-Host ('Rapports et sauvegardes : '+$root)
