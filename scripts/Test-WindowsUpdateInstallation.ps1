#requires -Version 5.1
[CmdletBinding()]
param([switch]$Worker,[switch]$NewTest)
$ErrorActionPreference='Stop'
$OutputEncoding=[Text.UTF8Encoding]::new($false)
try {[Console]::OutputEncoding=$OutputEncoding} catch {}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Worker) {throw 'Le processus de test doit être administrateur.'}
    $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'"'+$(if ($NewTest) {' -NewTest'} else {''})
    $child=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($child.ExitCode -ne 0) {throw 'Le test ne s''est pas terminé normalement. Consulter les rapports IQ.'}
    return
}
function Save-UpdateTestState($Value,[string]$Folder) {
    $Value.updated_utc=[DateTime]::UtcNow.ToString('o')
    $path=Join-Path $Folder 'state.json';$temp=$path+'.tmp'
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 18))
    $stream=[IO.File]::Open($temp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
    if (Test-Path $path) {[IO.File]::Replace($temp,$path,($path+'.bak'))} else {[IO.File]::Move($temp,$path)}
}
function Read-UpdateTestState([string]$Folder) {
    try {return Get-Content (Join-Path $Folder 'state.json') -Encoding UTF8 -Raw | ConvertFrom-Json} catch {
        return Get-Content (Join-Path $Folder 'state.json.bak') -Encoding UTF8 -Raw | ConvertFrom-Json
    }
}
function Test-UpdateTestRebootPending {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}
function Set-UpdateTestVerifiedStatus($Value) {
    $Value.reboot_pending=Test-UpdateTestRebootPending
    if ($Value.reboot_pending) {
        if ($Value.restarts -ge 6) {$Value.status='needs_attention';$Value.message='Un redémarrage reste signalé après la limite des essais. Vérifier le rapport.'}
        else {$Value.status='restart_pending';$Value.restarts++;$Value.message='Windows signale un redémarrage nécessaire. Redémarrage automatique dans 60 secondes, puis nouvelle vérification.'}
    } else {
        $Value.status='completed';$Value.message='Recherche finale réussie : aucun correctif ni pilote restant proposé et aucun redémarrage Windows en attente.'
    }
}
function Export-UpdateTestReport($Value) {
    $folder=[string]$Value.report_directory
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'result.json'),($Value | ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))
    $lines=@('TEST D''INSTALLATION WINDOWS UPDATE',('État : '+$Value.status),('Message : '+$Value.message),('Passes : '+$Value.passes.Count),('Redémarrages demandés : '+$Value.restarts),'')
    foreach ($pass in $Value.passes) {
        $lines+=@(('Passe : '+$pass.status),('Message : '+$pass.message))
        foreach ($update in $pass.updates) {$lines+=@(($update.status+' | '+$update.title+' | '+$update.hresult))}
        foreach ($update in $pass.excluded) {$lines+=@(('Exclue : '+$update.title+' | '+$update.reason))}
    }
    $lines+=@('','Dernière recherche :')
    foreach ($update in $Value.verification.remaining) {$lines+=@(('Encore proposée : '+$update.title))}
    [IO.File]::WriteAllLines((Join-Path $folder 'Lisez-moi.txt'),$lines,[Text.UTF8Encoding]::new($false))
    $zip=$folder+'.zip';$temporary=$folder+'.nouveau.zip'
    Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $temporary -Force
    Move-Item -LiteralPath $temporary -Destination $zip -Force
    try {
        if (Test-Path $Value.kit_path -PathType Container) {
            $usb=Join-Path $Value.kit_path 'Rapports';New-Item -ItemType Directory -Path $usb -Force | Out-Null
            Copy-Item -LiteralPath $zip -Destination $usb -Force
        }
    } catch {}
}
if ($Worker) {
    . (Join-Path $PSScriptRoot 'WindowsUpdate-Diagnostic.ps1')
    . (Join-Path $PSScriptRoot 'WindowsUpdate-InstallTest.ps1')
    $mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-WindowsUpdateInstallationTest')
    $owned=$false
    try {try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if (-not $owned) {return}
        $state=Read-UpdateTestState $PSScriptRoot
        $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        $resume=Get-AtelierTestUpdateResumeAction $state $boot
        if ($resume -in @('finished','wait_for_restart')) {return}
        if ($resume -eq 'verify_interrupted') {
            # Un arrêt pendant une installation peut masquer son résultat. Vérifier et signaler cette incertitude.
            $state.status='needs_attention';$state.message='Installation interrompue sans code de retour confirmé. Nouvelle recherche de diagnostic, aucune réinstallation automatique.'
            $state.passes+=@($state.active_pass);$state.active_pass=$null
            $state.verification=Invoke-AtelierTestUpdatePass -VerifyOnly
            Save-UpdateTestState $state $PSScriptRoot;Export-UpdateTestReport $state
            Unregister-ScheduledTask -TaskName $state.task_name -Confirm:$false
            return
        }
        $os=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $state.windows=[pscustomobject]@{display_version=$os.DisplayVersion;build=$os.CurrentBuildNumber;ubr=$os.UBR;edition=$os.EditionID}
        $state.status='running';$state.boot=$boot;$state.message='Recherche de contrôle Windows Update en cours.'
        Save-UpdateTestState $state $PSScriptRoot
        $check=Invoke-AtelierTestUpdatePass -VerifyOnly -OnProgress {
            param($Message);$state.message=$Message;Save-UpdateTestState $state $PSScriptRoot
        }
        $state.verification=$check
        if ($check.status -eq 'verified') {
            Set-UpdateTestVerifiedStatus $state
        } elseif ($check.status -ne 'remaining') {
            $state.status='needs_attention';$state.message=$check.message
        } elseif ($state.passes.Count -ge 5) {
            $state.status='needs_attention';$state.message='Limite de cinq passes atteinte. Des mises à jour restent proposées ; consulter le rapport.'
        } else {
            $state.active_pass=[pscustomobject]@{status='searching';updates=@()}
            Save-UpdateTestState $state $PSScriptRoot
            $pass=Invoke-AtelierTestUpdatePass -OnProgress {
                param($Message);$state.message=$Message;Save-UpdateTestState $state $PSScriptRoot
            } -Checkpoint {
                param($Value);$state.active_pass=$Value;Save-UpdateTestState $state $PSScriptRoot
            }
            $state.passes+=@($pass);$state.active_pass=$null
            if ($pass.status -in @('installed','reboot_required')) {
                if ($state.restarts -ge 6) {
                    $state.status='needs_attention';$state.message='Limite de redémarrages atteinte. Vérifier le rapport avant de poursuivre.'
                } else {
                    $state.status='restart_pending';$state.restarts++;$state.boot=$boot
                    $state.message='Redémarrage automatique dans 60 secondes. Le test reprendra au démarrage suivant.'
                }
            } elseif ($pass.status -eq 'verified') {
                $state.verification=$pass;Set-UpdateTestVerifiedStatus $state
            } else {$state.status='needs_attention';$state.message=$pass.message}
        }
        $state.updated_utc=[DateTime]::UtcNow.ToString('o')
        Save-UpdateTestState $state $PSScriptRoot;Export-UpdateTestReport $state
        if ($state.status -eq 'restart_pending') {
            & (Join-Path $env:SystemRoot 'System32\shutdown.exe') /r /t 60 /d p:2:4 /c 'Test Atelier : mises à jour Windows, reprise automatique après redémarrage.'
            if ($LASTEXITCODE -ne 0) {throw 'La demande de redémarrage Windows a échoué.'}
        } else {Unregister-ScheduledTask -TaskName $state.task_name -Confirm:$false}
    } catch {
        if ($state) {
            $state.status='needs_attention';$state.message=$_.Exception.Message
            Save-UpdateTestState $state $PSScriptRoot;Export-UpdateTestReport $state
            Unregister-ScheduledTask -TaskName $state.task_name -Confirm:$false -ErrorAction SilentlyContinue
        }
        throw
    } finally {if ($owned) {$mutex.ReleaseMutex()};$mutex.Dispose()}
    return
}
if ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) {throw 'Lancer le test sur le PC Windows, pas sur le serveur .250.'}
foreach ($name in @('AtelierPXE-Preparation','AtelierPXE-Maintenance')) {
    if ((Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).State -eq 'Running') {throw 'Attendre la fin de la préparation Atelier avant ce test.'}
}
if ($NewTest -and @(Get-ScheduledTask -TaskName 'AtelierPXE-TestWindowsUpdateInstallation-*' -ErrorAction SilentlyContinue).Count) {throw 'Un test possède encore une tâche de reprise. Attendre sa fin avant un nouvel essai.'}
$work=$null
if (-not $NewTest) {
    $previous=@(Get-ChildItem -LiteralPath $env:ProgramFiles -Directory -Filter 'AtelierPXE-WindowsUpdateTest-*' | Sort-Object CreationTimeUtc -Descending)
    foreach ($folder in $previous) {
        if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) {continue}
        try {$candidate=Read-UpdateTestState $folder.FullName} catch {continue}
        if ($candidate.revision -eq 'WU-INSTALL-1') {$work=$folder.FullName;break}
    }
}
if (-not $work) {
    $id=[guid]::NewGuid().ToString('N');$work=Join-Path $env:ProgramFiles ('AtelierPXE-WindowsUpdateTest-'+$id)
    New-Item -ItemType Directory -Path $work | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    Set-Acl -LiteralPath $work -AclObject $acl
    foreach ($file in @('Test-WindowsUpdateInstallation.ps1','WindowsUpdate-InstallTest.ps1','WindowsUpdate-Diagnostic.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $work
    }
    $report=Join-Path $env:SystemDrive ('IQ_\Rapports\WindowsUpdateInstallation\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$id.Substring(0,8))
    $state=[pscustomobject]@{revision='WU-INSTALL-1';computer_name=$env:COMPUTERNAME;windows=$null;reboot_pending=$false;status='new';message='Test prêt à démarrer.';started_utc=[DateTime]::UtcNow.ToString('o');updated_utc=$null;boot='';passes=@();active_pass=$null;verification=$null;restarts=0;kit_path=$PSScriptRoot;report_directory=$report;task_name=('AtelierPXE-TestWindowsUpdateInstallation-'+$id)}
    Save-UpdateTestState $state $work
    $action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $work 'Test-WindowsUpdateInstallation.ps1')+'" -Worker')
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $trigger=New-ScheduledTaskTrigger -AtStartup;$trigger.Delay='PT60S'
    # Aucun arrêt forcé d’un installateur si la fenêtre du lanceur est fermée.
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $state.task_name -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force | Out-Null
}
$state=Read-UpdateTestState $work
Write-Host 'TEST : installation Windows Update, pilotes et firmware inclus, avec redémarrages automatiques.' -ForegroundColor Cyan
Write-Host 'Brancher le portable sur secteur. La reprise est enregistrée sur le PC ; la clé USB ne doit pas rester branchée.'
if ($state.status -notin @('completed','needs_attention')) {
    Start-ScheduledTask -TaskName $state.task_name
    $last='';$monitor=[Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $state=Read-UpdateTestState $work
        if ($state.message -ne $last) {Write-Host $state.message;$last=$state.message}
        if ($state.status -in @('restart_pending','completed','needs_attention')) {break}
        $task=Get-ScheduledTask -TaskName $state.task_name -ErrorAction SilentlyContinue
        if ($monitor.Elapsed.TotalSeconds -gt 15 -and (-not $task -or $task.State -ne 'Running')) {
            Write-Warning 'Le processus ne tourne plus sans bilan confirmé. Rouvrir ce lanceur pour vérifier la reprise.'
            Export-UpdateTestReport $state
            break
        }
        Start-Sleep -Seconds 2
    }
}
try {
    $zip=$state.report_directory+'.zip'
    if (Test-Path $zip) {
        $copies=Join-Path $PSScriptRoot 'Rapports'
        New-Item -ItemType Directory -Path $copies -Force | Out-Null
        Copy-Item -LiteralPath $zip -Destination $copies -Force
    }
} catch {Write-Warning 'Le ZIP reste disponible dans le dossier IQ du poste.'}
Write-Host ('Rapport : '+$state.report_directory+'.zip') -ForegroundColor $(if ($state.status -eq 'completed') {'Green'} else {'Yellow'})
Write-Host $state.message
if ($state.status -eq 'restart_pending') {Write-Host 'Après le redémarrage, le test continue sous SYSTEM. Rouvrir ce même lanceur pour voir la progression.'}
if (Test-Path (Join-Path $state.report_directory 'Lisez-moi.txt')) {Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $state.report_directory 'Lisez-moi.txt')+'"')}
