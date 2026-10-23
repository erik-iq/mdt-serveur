#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath='C:\ProgramData\AtelierPXE',[switch]$Worker)

# La tâche SYSTEM termine Windows Update avant de libérer le premier compte.
function Wait-AtelierWindowsUpdateFirst {
    param([string]$DataPath)
    $path=Join-Path $DataPath 'windows-update-result.json'
    if (Test-Path $path) {
        try {
            $saved=Read-AtelierSharedUtf8File -Path $path | ConvertFrom-Json
            if ($saved.source -eq 'windows_update' -and $saved.status -eq 'completed') { return $true }
        } catch { if (-not (Test-AtelierFileSharingViolation $_.Exception)) { throw } }
    }
    $powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action=New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $DataPath 'WindowsUpdate-First.ps1')+'" -DataPath "'+$DataPath+'" -Worker')
    $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 14)))
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    # Ne pas remplacer une tâche dont une installation est encore active.
    if (-not (Get-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst' -ErrorAction SilentlyContinue)) {
        Register-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    }
    Start-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst'
    # Attendre les reprises sans lancer de logiciel dans le compte interactif.
    $deadline=[DateTime]::UtcNow.AddHours(3)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path $path) {
            try {
                $saved=Read-AtelierSharedUtf8File -Path $path | ConvertFrom-Json
                if ($saved.source -ne 'windows_update') { throw 'État Windows Update inattendu : logiciels bloqués.' }
                if ($saved.status -eq 'completed') { return $true }
                if ($saved.status -eq 'needs_attention') { throw ('Windows Update à vérifier avant les logiciels : '+$saved.message) }
            } catch {
                # Une observation impossible ne constitue ni un échec ni une réussite de Windows Update.
                if (-not (Test-AtelierFileSharingViolation $_.Exception)) { throw }
            }
        }
        Start-Sleep -Seconds 5
    }
    throw 'Windows Update est encore en cours après trois heures. Les logiciels restent en attente ; les tâches et rapports sont conservés.'
}

function Invoke-AtelierWindowsUpdateFirstWorker {
    param([string]$DataPath)
    . (Join-Path $DataPath 'Unattend.ps1')
    . (Join-Path $DataPath 'Reporting.ps1')
    . (Join-Path $DataPath 'HP-ImageAssistant.ps1')
    . (Join-Path $DataPath 'Client-WindowsUpdate.ps1')
    $mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-WindowsUpdateFirst')
    $owned=$mutex.WaitOne(0)
    if (-not $owned) { $mutex.Dispose();return }
    function Publish-WindowsUpdateFirst([string]$Status,[string]$Message,$Windows) {
        $stamp=[DateTime]::UtcNow.ToString('o')
        $progress=@{status=$Status;progress=10;message=$Message;timestamp=$stamp;detail=@{percent=-1}}
        Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'progress.json') -Content ($progress | ConvertTo-Json -Depth 6) -NoBackup | Out-Null
        if ($Windows) {
            $maintenance=@{status=$Status;attempts=0;passes=0;reboots=$Windows.restarts;windows=$Windows;store=$null;message=$Message;timestamp=$stamp}
            Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'maintenance.json') -Content ($maintenance | ConvertTo-Json -Depth 22) -NoBackup | Out-Null
        }
        Send-AtelierWindowsProgress $DataPath $Status 10 $Message
    }
    try {
        $payload=Get-Content (Join-Path $DataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
        Initialize-AtelierReportTrust -DataPath $DataPath
        Publish-WindowsUpdateFirst 'running' 'Windows Update avant les logiciels : recherche et installation automatiques.' $null
        $wu=Invoke-AtelierAutomaticWindowsUpdate -DataPath $DataPath -OnProgress {
            param($Message)
            Publish-WindowsUpdateFirst 'running' $Message $null
        }
        if ($wu.status -eq 'completed') {
            Publish-WindowsUpdateFirst 'running' 'Windows Update terminé et vérifié. Préparation des logiciels puis des pilotes constructeur.' $wu
            Unregister-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst' -Confirm:$false -ErrorAction SilentlyContinue
            return
        }
        if ($wu.status -eq 'reboot_pending') {
            # La préparation interactive reste inscrite et reprend à la connexion suivante.
            # La tâche SYSTEM reprend même si le compte n’est pas connecté.
            $boot=Get-AtelierHpBootIdentity
            $restartPath=Join-Path $DataPath 'windows-update-first-restart.json'
            if (Test-Path $restartPath) {
                $restart=Read-AtelierSharedUtf8File -Path $restartPath | ConvertFrom-Json
                if ($restart.boot_id -eq $boot) {
                    Publish-WindowsUpdateFirst 'reboot_pending' $wu.message $wu
                    return
                }
            }
            if ($payload.settings.unattended) {
                $account=Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
                if (-not $account -or -not $account.Enabled) { throw 'Compte de reprise Windows indisponible.' }
                $winlogon='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                Set-ItemProperty $winlogon DefaultUserName $account.Name
                Set-ItemProperty $winlogon DefaultDomainName $env:COMPUTERNAME
                Set-ItemProperty $winlogon DefaultPassword ''
                Set-ItemProperty $winlogon AutoAdminLogon '1'
                New-ItemProperty $winlogon AutoLogonCount -Value 1 -PropertyType DWord -Force | Out-Null
            }
            $message='Windows Update : redémarrage automatique dans 60 secondes. La recherche reprend avant les logiciels.'
            Publish-WindowsUpdateFirst 'reboot_pending' $message $wu
            Write-AtelierVerifiedUtf8File -Path $restartPath -Content (@{boot_id=$boot;requested_at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json) -NoBackup | Out-Null
            & shutdown.exe /r /t 60 /d p:2:17 /c $message | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Remove-Item -LiteralPath $restartPath -Force
                throw 'Windows a refusé le redémarrage Windows Update. Les logiciels restent bloqués.'
            }
            return
        }
        $status=if ($wu.status -eq 'needs_attention') {'needs_attention'} else {'running'}
        Publish-WindowsUpdateFirst $status $wu.message $wu
        if ($status -eq 'needs_attention') { Unregister-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst' -Confirm:$false -ErrorAction SilentlyContinue }
    } catch {
        if (Test-AtelierFileSharingViolation $_.Exception) {
            # Garder les checkpoints intacts et la tâche de reprise inscrite.
            try { Add-Content -LiteralPath (Join-Path $DataPath 'maintenance.log') -Encoding UTF8 -Value ((Get-Date -Format o)+' État Windows Update occupé ; nouvelle tentative automatique, logiciels en attente.') } catch { }
            return
        }
        $message='Windows Update avant les logiciels : '+$_.Exception.Message
        # Un échec du pilotage doit aussi réveiller la préparation en attente.
        $path=Join-Path $DataPath 'windows-update-result.json'
        $failure=if (Test-Path $path) {Read-AtelierSharedUtf8File -Path $path | ConvertFrom-Json} else {[pscustomobject]@{source='windows_update';status='needs_attention';message=$message;restarts=0}}
        $failure.status='needs_attention';$failure.message=$message
        Write-AtelierVerifiedUtf8File -Path $path -Content ($failure | ConvertTo-Json -Depth 22) -NoBackup | Out-Null
        Publish-WindowsUpdateFirst 'needs_attention' $message $failure
        Unregister-ScheduledTask -TaskName 'AtelierPXE-WindowsUpdateFirst' -Confirm:$false -ErrorAction SilentlyContinue
    } finally { $mutex.ReleaseMutex();$mutex.Dispose() }
}

if ($Worker) { Invoke-AtelierWindowsUpdateFirstWorker -DataPath $DataPath }
