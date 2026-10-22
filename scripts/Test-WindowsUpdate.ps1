#requires -Version 5.1
[CmdletBinding()]
param([switch]$Worker,[string]$OutputPath,[ValidateRange(30,600)][int]$SearchTimeoutSeconds=300)
$ErrorActionPreference='Stop'
$OutputEncoding=[Text.UTF8Encoding]::new($false)
try {[Console]::OutputEncoding=$OutputEncoding} catch { }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Worker) { throw 'Le diagnostic système exige une élévation administrateur.' }
    $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -SearchTimeoutSeconds '+$SearchTimeoutSeconds
    $child=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -PassThru -Wait
    if ($child.ExitCode -ne 0) { throw 'Le diagnostic a échoué. Consulter la fenêtre administrateur et les rapports IQ.' }
    return
}
. (Join-Path $PSScriptRoot 'WindowsUpdate-Diagnostic.ps1')
function Save-TestJson([string]$Path,$Value) {
    $temp=$Path+'.tmp'
    [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
if ($Worker) {
    if (-not $OutputPath -or -not (Test-Path $OutputPath -PathType Container)) {throw 'Dossier de diagnostic absent.'}
    $report=[ordered]@{schema=1;started_utc=[DateTime]::UtcNow.ToString('o');finished_utc=$null;status='running';context=$identity.Name;windows=$null;services=@();policies=@{};reboot_pending=$false;scans=@();errors=@();events=@();action='scan_only'}
    try {
        $os=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $report.windows=@{display_version=$os.DisplayVersion;build=$os.CurrentBuildNumber;ubr=$os.UBR;edition=$os.EditionID}
        foreach ($name in @('wuauserv','BITS','CryptSvc','UsoSvc')) {
            $svc=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'")
            if ($svc) {$report.services+=@{name=$name;state=$svc.State;start_mode=$svc.StartMode}}
        }
        foreach ($path in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU')) {
            $policy=Get-ItemProperty $path -ErrorAction SilentlyContinue
            foreach ($name in @('UseWUServer','DoNotConnectToWindowsUpdateInternetLocations','DisableWindowsUpdateAccess','SetDisableUXWUAccess','NoAutoUpdate','DisableDualScan')) {
                if ($policy -and $null -ne $policy.$name) {$report.policies[$name]=$policy.$name}
            }
        }
        $report.reboot_pending=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        $sources=@('windows_update')
        if ($report.policies.UseWUServer -eq 1) {$sources+=@('configured')}
        foreach ($source in $sources) {
            $scan=Invoke-AtelierUpdateScan -Source $source -TimeoutSeconds $SearchTimeoutSeconds -OnProgress {
                param($Message)
                Save-TestJson (Join-Path $OutputPath 'progress.json') @{status='running';message=$Message;updated_utc=[DateTime]::UtcNow.ToString('o')}
            }
            $report.scans+=@($scan)
            Save-TestJson (Join-Path $OutputPath 'result.json') $report
        }
        $report.status=if (@($report.scans | Where-Object {$_.status -in @('failed','timeout','incomplete')}).Count) {'needs_attention'} else {'completed'}
    } catch { $report.status='failed';$report.errors+=@($_.Exception.Message) }
    try {
        $report.events=@(Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 30 -ErrorAction Stop | ForEach-Object {@{time_utc=$_.TimeCreated.ToUniversalTime().ToString('o');id=$_.Id;level=$_.LevelDisplayName;message=$_.Message}})
    } catch { $report.errors+=@('Journal Windows Update indisponible : '+$_.Exception.Message) }
    $report.finished_utc=[DateTime]::UtcNow.ToString('o')
    Save-TestJson (Join-Path $OutputPath 'result.json') $report
    Save-TestJson (Join-Path $OutputPath 'progress.json') @{status=$report.status;message='Analyse terminée. Aucune mise à jour installée et aucun redémarrage demandé.'}
    return
}
foreach ($name in @('AtelierPXE-Preparation','AtelierPXE-Maintenance')) {
    if ((Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).State -eq 'Running') {throw 'Attendre la fin de la préparation Atelier avant ce test.'}
}
$id=[guid]::NewGuid().ToString('N')
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$work=Join-Path $env:ProgramFiles ('AtelierPXE-Diagnostic-'+$id)
New-Item -ItemType Directory -Path $work | Out-Null
# Le script lancé par SYSTEM doit être inaccessible en écriture aux comptes ordinaires.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $work -AclObject $acl
foreach ($file in @('Test-WindowsUpdate.ps1','WindowsUpdate-Diagnostic.ps1')) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $work}
$taskName='AtelierPXE-TestWindowsUpdate-'+$id
$arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $work 'Test-WindowsUpdate.ps1')+'" -Worker -OutputPath "'+$work+'" -SearchTimeoutSeconds '+$SearchTimeoutSeconds
$taskAction=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arguments
$taskPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$taskSettings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 23) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$registered=$false;$finished=$false
try {
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
    $registered=$true
    Write-Host 'TEST WINDOWS UPDATE : recherche uniquement, sous le compte SYSTEM.' -ForegroundColor Cyan
    Write-Host 'Aucune installation, aucun changement de stratégie et aucun redémarrage.'
    Write-Host 'La première recherche peut prendre cinq minutes. Garder Internet connecté.'
    Start-ScheduledTask -TaskName $taskName
    $clock=[Diagnostics.Stopwatch]::StartNew();$last=''
    while ($clock.Elapsed.TotalMinutes -lt 22) {
        $progressPath=Join-Path $work 'progress.json'
        if (Test-Path $progressPath) {
            $progress=Get-Content $progressPath -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($progress.message -ne $last) {Write-Host $progress.message;$last=$progress.message}
            if ($progress.status -ne 'running') {$finished=$true;break}
        }
        $task=Get-ScheduledTask -TaskName $taskName
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        if ($task.State -ne 'Running' -and $clock.Elapsed.TotalSeconds -gt 10 -and $info.LastRunTime -gt (Get-Date).AddMinutes(-23)) {break}
        Start-Sleep -Seconds 2
    }
} catch {
    Save-TestJson (Join-Path $work 'launcher-error.json') @{status='failed';message=$_.Exception.Message}
} finally {
    if ($registered) {
        if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {Stop-ScheduledTask -TaskName $taskName}
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
$destination=Join-Path $env:SystemDrive ('IQ_\Rapports\WindowsUpdate\'+$stamp+'-'+$id.Substring(0,8))
New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($name in @('progress.json','result.json','launcher-error.json')) {
    $path=Join-Path $work $name
    if (Test-Path $path) {Copy-Item -LiteralPath $path -Destination $destination}
}
if (-not $finished -and -not (Test-Path (Join-Path $destination 'launcher-error.json'))) {
    Save-TestJson (Join-Path $destination 'launcher-error.json') @{status='failed';message='Le processus de diagnostic n''a pas confirmé sa fin. Aucune conclusion Windows à jour.'}
}
$summary=@('DIAGNOSTIC WINDOWS UPDATE','Recherche uniquement. Aucune installation et aucun redémarrage.','')
if (Test-Path (Join-Path $destination 'result.json')) {
    $result=Get-Content (Join-Path $destination 'result.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    $summary+=@(('État : '+$result.status),('Compte : '+$result.context))
    foreach ($scan in $result.scans) {
        $summary+=@('',('Source : '+$scan.source),('Résultat : '+$scan.status),('Message : '+$scan.message),('Nombre total : '+$scan.count),('Avec les anciens filtres : '+$scan.previous_filter_count),('HRESULT : '+$scan.hresult))
        foreach ($update in $scan.updates) {$summary+=@('  '+$update.title)}
    }
}
[IO.File]::WriteAllLines((Join-Path $destination 'Lisez-moi.txt'),$summary,[Text.UTF8Encoding]::new($false))
$zip=$destination+'.zip'
Compress-Archive -Path (Join-Path $destination '*') -DestinationPath $zip -Force
Write-Host ('RAPPORT TERMINÉ : '+$zip) -ForegroundColor $(if ($finished -and $result.status -eq 'completed') {'Green'} else {'Yellow'})
try {
    $usbReports=Join-Path $PSScriptRoot 'Rapports'
    New-Item -ItemType Directory -Path $usbReports -Force | Out-Null
    Copy-Item -LiteralPath $zip -Destination $usbReports
    Write-Host ('Copie du ZIP dans : '+$usbReports)
} catch {Write-Warning 'Copie sur la clé impossible. Le ZIP reste dans IQ_\Rapports\WindowsUpdate.'}
Remove-Item -LiteralPath $work -Recurse -Force
Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $destination 'Lisez-moi.txt')+'"')
if (-not $finished) {throw 'Diagnostic incomplet. Transmettre le ZIP pour analyse.'}
