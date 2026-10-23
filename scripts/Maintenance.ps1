#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE', [string]$ToolsPath = 'C:\IQ_')
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference = 'Stop'
. (Join-Path $DataPath 'Unattend.ps1')
. (Join-Path $DataPath 'Updates.ps1')
. (Join-Path $PSScriptRoot 'IQ-Paths.ps1')
. (Join-Path $DataPath 'HP-ImageAssistant.ps1')
. (Join-Path $DataPath 'Client-Software.ps1')
if (Test-Path (Join-Path $DataPath 'Reporting.ps1')) { . (Join-Path $DataPath 'Reporting.ps1') }
$statePath = Join-Path $DataPath 'maintenance.json'
$logPath = Join-Path $DataPath 'maintenance.log'
$mutex = New-Object Threading.Mutex($false,'Global\AtelierPXE-Maintenance')
$owned = $mutex.WaitOne(0)
if (-not $owned) { $mutex.Dispose(); exit 0 }
$state = [pscustomobject]@{status='running';attempts=0;passes=0;reboots=0;windows=$null;store=$null;message='Finalisation du poste';timestamp=''}
function Save-Maintenance([string]$Status,[int]$Percent,[string]$Message) {
    $state.status=$Status; $state.message=$Message; $state.timestamp=[DateTime]::UtcNow.ToString('o')
    Write-AtelierVerifiedUtf8File -Path $statePath -Content ($state | ConvertTo-Json -Depth 8) -NoBackup | Out-Null
    Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'progress.json') -Content (@{status=$Status;progress=$Percent;message=$Message;timestamp=$state.timestamp;detail=$script:updateDetail} | ConvertTo-Json -Depth 5) -NoBackup | Out-Null
    Add-Content -LiteralPath $logPath -Value ($state.timestamp + ' ' + $Message) -Encoding UTF8
    if (Get-Command Send-AtelierWindowsProgress -ErrorAction SilentlyContinue) { Send-AtelierWindowsProgress $DataPath $Status $Percent $Message }
}
function Finish-Maintenance {
    # Au démarrage SYSTEM peut finir avant Winlogon : laisser sa connexion unique
    # présenter le bilan. La fenêtre retire ensuite les paramètres de connexion.
    if (-not $state.final_restart.completed_at -or (Get-Process explorer -ErrorAction SilentlyContinue)) { Disable-AtelierAutoLogon }
    if (Get-Command Complete-AtelierReport -ErrorAction SilentlyContinue) { Complete-AtelierReport $DataPath $ToolsPath }
    $cleanupRequested=$false
    $payloadFile=Join-Path $DataPath 'personalization.json'
    if (Test-Path $payloadFile) { $cleanupRequested=[bool](Get-Content $payloadFile -Encoding UTF8 -Raw | ConvertFrom-Json).deployment.cleanup_after_reporting }
    if ($cleanupRequested) {
        . (Join-Path $DataPath 'Finalization.ps1')
        if (Complete-AtelierLocalCleanup -DataPath $DataPath -ToolsPath $ToolsPath) { return }
    }
    $configuration=Join-Path $DataPath 'reporting.json'
    $sent=$false; $expired=$false
    $receipt=Get-AtelierIQFile $ToolsPath 'Rapports' 'Transmission-Rapport.json'
    if (Test-Path $receipt) {
        try { $sent=(Get-Content $receipt -Encoding UTF8 -Raw | ConvertFrom-Json).status -eq 'sent' } catch { }
    }
    if (Test-Path $configuration) {
        try { $expired=[DateTime]::Parse((Get-Content $configuration -Encoding UTF8 -Raw | ConvertFrom-Json).expires) -lt [DateTime]::UtcNow } catch { }
    }
    # Si le serveur est indisponible, conserver seulement la reprise bornée de transmission.
    if (-not (Test-Path $configuration) -or ($sent -and -not $cleanupRequested) -or $expired) { Unregister-ScheduledTask -TaskName 'AtelierPXE-Maintenance' -Confirm:$false -ErrorAction SilentlyContinue }
    # La fenêtre conserve sa tâche jusqu’à l’affichage du bilan après reconnexion.
}

function Request-AtelierFinalRestart {
    if ($state.final_restart.requested_at) { return }
    if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)^(winget|msiexec|HPImageAssistant|HpFirmwareUpdRec.*|HPBIOSUPDREC.*|HPBIOSUpdate.*)$' }).Count) {
        Save-Maintenance 'retry_pending' 95 'Un installateur est encore actif. Redémarrage différé ; reprise automatique dès le prochain contrôle.'
        return
    }
    # Le compte intégré a été préparé sans mot de passe par le déploiement.
    # Une seule reconnexion permet de présenter le bilan ; Finish-Maintenance la désactive.
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
    $state.final_restart | Add-Member NoteProperty requested_at ([DateTime]::UtcNow.ToString('o')) -Force
    Save-Maintenance 'reboot_pending' 95 'Installations terminées. Redémarrage automatique dans 60 secondes, puis contrôle et bilan de la préparation.'
    & shutdown.exe /r /t 60 /d p:2:17 /c 'Atelier PXE : fin des installations. Reprise automatique du contrôle après redémarrage.' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $state.final_restart.requested_at=$null
        throw 'Windows a refusé le redémarrage de fin de préparation.'
    }
}

try {
    if (Test-Path $statePath) {
        $loaded=Get-Content $statePath -Encoding UTF8 -Raw | ConvertFrom-Json
        foreach ($property in $state.PSObject.Properties) {
            if (-not $loaded.PSObject.Properties[$property.Name]) { $loaded | Add-Member NoteProperty $property.Name $property.Value }
        }
        $state=$loaded
    }
    if (-not $state.PSObject.Properties['windows_history']) { $state | Add-Member NoteProperty windows_history @() }
    $payload = Get-Content (Join-Path $DataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    # Une ancienne tâche de démarrage ne doit pas finaliser la nouvelle phase Windows Update.
    if ($payload.deployment.automatic_windows_update -and -not (Test-Path (Join-Path $DataPath 'result.json'))) { return }
    $customization = Get-Content (Join-Path $DataPath 'result.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($payload.deployment.automatic_windows_update -and $customization.status -ne 'completed') { return }
    $software=Get-AtelierSoftwareSummary -Packages @($payload.settings.winget_packages) -Results @($customization.applications)
    if ($state.final_restart -and -not $state.final_restart.completed_at) {
        $boot=Get-AtelierHpBootIdentity
        if (([datetime]$boot).ToUniversalTime() -eq ([datetime]$state.final_restart.boot_id).ToUniversalTime()) {
            Request-AtelierFinalRestart
            return
        }
        # Vérifier les applications dans ce nouveau démarrage, sans les réinstaller.
        foreach ($entry in @($customization.applications)) {
            if ($entry.id -notin @($payload.settings.winget_packages)) { continue }
            $installed=Get-AtelierInstalledClientSoftware -Key $entry.id
            if ($installed) {
                foreach ($key in @('verification','tool','version')) {
                    if ($installed[$key]) { $entry | Add-Member NoteProperty $key $installed[$key] -Force }
                }
                $entry.status='completed'
            } else { $entry.status='failed';$entry | Add-Member NoteProperty reason 'Installation non retrouvée après redémarrage.' -Force }
        }
        $customization.restart_needed=$false
        $state.reboot_required=$false;$state.reboots++
        $state.final_restart | Add-Member NoteProperty completed_at ([DateTime]::UtcNow.ToString('o')) -Force
        $state.final_restart | Add-Member NoteProperty verified_boot_id $boot -Force
        $state.status='running'
        $hpPath=Join-Path $DataPath 'hpia-result.json'
        if (Test-Path $hpPath) {
            $savedHp=Get-Content $hpPath -Encoding UTF8 -Raw | ConvertFrom-Json
            $savedHp.reboot_required=$false
            if ($savedHp.status -eq 'completed') {
                $savedHp | Add-Member NoteProperty message_before_restart $savedHp.message -Force
                $savedHp.message='Installations HP terminées ; redémarrage effectué.'
            }
            $savedHp | Add-Member NoteProperty reboot_completed_boot $boot -Force
            Write-AtelierVerifiedUtf8File -Path $hpPath -Content ($savedHp | ConvertTo-Json -Depth 14) -NoBackup | Out-Null
        }
        $software=Get-AtelierSoftwareSummary -Packages @($payload.settings.winget_packages) -Results @($customization.applications)
        $customization | Add-Member NoteProperty software_status $software.status -Force
        $customization | Add-Member NoteProperty software_summary $software -Force
        Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'result.json') -Content ($customization | ConvertTo-Json -Depth 12) -NoBackup | Out-Null
    }
    $windowsContinuation=$payload.deployment.automatic_windows_update -and $state.windows.status -in @('installing','retry_pending','reboot_pending')
    if ($state.status -in @('completed','needs_attention') -and $software.status -eq 'completed' -and $customization.software_status -ne 'needs_attention' -and -not $windowsContinuation) { Finish-Maintenance; return }
    if ($customization.status -ne 'completed') { throw 'Les logiciels doivent être terminés avant la finalisation du poste.' }
    $hpContinuation=(($payload.deployment.allow_bios_restart -or $payload.deployment.cached_windows_updates -or $payload.deployment.automatic_windows_update) -and $state.status -in @('reboot_pending','retry_pending')) -or $windowsContinuation
    if (-not $hpContinuation) { $state.attempts++ }
    if ($state.attempts -gt 6) { throw 'Limite de tentatives atteinte.' }
    $state | Add-Member NoteProperty reboot_required ([bool]$customization.restart_needed -or [bool]$state.reboot_required -or $state.status -eq 'reboot_pending') -Force
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    # Ces anciens paramètres sont ignorés, y compris dans un ancien dossier de travail.
    $state.windows=if ($payload.deployment.automatic_windows_update) { [pscustomobject]@{status='running';source='windows_update';message='Windows Update vérifié au début de la préparation pour les nouveaux déploiements.'} } elseif ($payload.deployment.cached_windows_updates) { [pscustomobject]@{status='running';message='Correctifs Windows depuis .250.'} } else { [pscustomobject]@{status='manual';count=0;reboot_required=$false;titles=@();message='Windows Update à lancer manuellement ; aucune recherche Atelier.'} }
    $state.store=[pscustomobject]@{status='manual';completion_verified=$false;message='Microsoft Store a actualiser manuellement ; aucune recherche Atelier.'}
    $softwareMessage=if (-not $software.selected.Count) { 'Aucun logiciel sélectionne : aucune installation demandée.' } elseif ($software.status -eq 'completed') { 'Logiciels vérifiés : '+$software.verified+'.' } else { 'Logiciels non installés ou non vérifiés : '+($software.missing -join ', ')+'.' }
    Save-Maintenance 'running' 80 ($softwareMessage+$(if ($payload.deployment.automatic_windows_update) {' Recherche et installation Windows Update automatiques.'}elseif ($payload.deployment.cached_windows_updates) {' Correctifs Windows depuis .250.'}else{' Windows Update et Microsoft Store restent manuels.'}))
    $hp=[pscustomobject]@{status='skipped';message='HP Image Assistant non coché : installation et SoftPaq non demandés.';exit_code=$null;reboot_required=$false;timestamp=[DateTime]::UtcNow.ToString('o')}
    if ('hpia' -in @($payload.settings.winget_packages)) {
        $hp=Invoke-AtelierHpia -DataPath $DataPath -ToolsPath $ToolsPath -OnProgress {
            param($Message)
            $script:updateDetail=@{percent=-1}
            Save-Maintenance 'running' 85 $Message
        }
    }
    $script:updateDetail=$null
    $state | Add-Member NoteProperty hpia $hp -Force
    if ($hp.resumed_after_reboot -and $state.hp_boot_id -ne $hp.boot_id) {
        # Ce démarrage réel a consommé les demandes de redémarrage des logiciels et de HP.
        $state.reboot_required=$false;$state.reboots++
        $state | Add-Member NoteProperty hp_boot_id $hp.boot_id -Force
        $customization | Add-Member NoteProperty restart_needed $false -Force
        Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'result.json') -Content ($customization | ConvertTo-Json -Depth 12) -NoBackup | Out-Null
    }
    if ($payload.deployment.allow_bios_restart -and $hp.status -in @('reboot_pending','retry_pending')) {
        $state.reboot_required=[bool]$hp.reboot_required
        Save-Maintenance $hp.status 90 $hp.message
        if ($hp.status -eq 'reboot_pending') {
            try { Request-AtelierHpBiosRestart -DataPath $DataPath }
            catch { Save-Maintenance 'reboot_pending' 90 $_.Exception.Message }
        }
        # Ne jamais terminer, retirer la tâche de démarrage ou nettoyer pendant un cycle BIOS.
        return
    }
    if ($hp.status -notin @('completed','skipped')) { $warnings.Add(('HP Image Assistant : '+$hp.message)) }
    if ($hp.reboot_required) { $state.reboot_required=$true }
    if ($payload.deployment.automatic_windows_update) {
        . (Join-Path $DataPath 'Client-WindowsUpdate.ps1')
        $wu=Invoke-AtelierAutomaticWindowsUpdate -DataPath $DataPath -OnProgress {
            param($Message)
            $script:updateDetail=@{percent=-1}
            Save-Maintenance 'running' 90 $Message
        }
        $script:updateDetail=$null;$state.windows=$wu
        if ($wu.status -eq 'installing') {Save-Maintenance 'retry_pending' 95 $wu.message;return}
        if ($wu.status -in @('retry_pending','reboot_pending')) {
            Save-Maintenance $wu.status 95 $wu.message
            if ($wu.status -eq 'reboot_pending') {
                if ($state.reboots -ge 6) {throw 'Limite des six reprises Windows atteinte. Rapports conservés.'}
                if (-not $state.final_restart -or $state.final_restart.completed_at) {
                    $state | Add-Member NoteProperty final_restart ([pscustomobject]@{boot_id=(Get-AtelierHpBootIdentity);requested_at=$null;completed_at=$null;purpose='windows_update'}) -Force
                }
                $state.reboot_required=$true
                Request-AtelierFinalRestart
            }
            return
        }
        if ($wu.status -ne 'completed') {$warnings.Add(('Windows Update : '+$wu.message))}
    } elseif ($payload.deployment.cached_windows_updates) {
        . (Join-Path $DataPath 'Client-KBUpdates.ps1')
        $kb=Invoke-AtelierCachedWindowsUpdates -DataPath $DataPath -OnProgress {
            param($Message)
            $script:updateDetail=@{percent=-1}
            Save-Maintenance 'running' 90 $Message
        }
        $script:updateDetail=$null
        $state.windows=$kb
        if ($kb.status -in @('retry_pending','reboot_pending')) {
            Save-Maintenance $kb.status 95 $kb.message
            if ($kb.status -eq 'reboot_pending') {
                if ($state.reboots -ge 6) { throw 'Limite des six reprises Windows atteinte. Rapports conservés.' }
                if (-not $state.final_restart -or $state.final_restart.completed_at) {
                    $state | Add-Member NoteProperty final_restart ([pscustomobject]@{boot_id=(Get-AtelierHpBootIdentity);requested_at=$null;completed_at=$null;purpose='windows_kb'}) -Force
                }
                $state.reboot_required=$true
                Request-AtelierFinalRestart
            }
            return
        }
        if ($kb.status -ne 'completed') { $warnings.Add(('Correctifs Windows : '+$kb.message)) }
    }
    $licenseScript = Get-AtelierIQFile $ToolsPath 'Licence' 'Verifier-Licence.ps1'
    if (Test-Path $licenseScript) {
        try { & $licenseScript } catch { Add-Content -LiteralPath $logPath -Value 'Relevé de licence indisponible ; aucun blocage de la préparation.' -Encoding UTF8 }
    }
    $message = 'Préparation terminée avec succès. '+$softwareMessage+$(if ($state.final_restart.completed_at) { ' Contrôle après redémarrage terminé.' } else { '' })
    if ($software.status -ne 'completed' -or $customization.software_status -eq 'needs_attention') { $warnings.Add(($softwareMessage+' Consulter C:\ProgramData\AtelierPXE\software-logs et le rapport.')) }
    if ($payload.deployment.final_restart -and -not $state.final_restart.completed_at -and -not $warnings.Count) {
        if (-not $state.final_restart) {
            $state | Add-Member NoteProperty final_restart ([pscustomobject]@{boot_id=(Get-AtelierHpBootIdentity);requested_at=$null;completed_at=$null}) -Force
        }
        $state.reboot_required=$true
        Request-AtelierFinalRestart
        return
    }
    if ($state.reboot_required) { $warnings.Add('Redémarrage nécessaire : le lancer depuis le menu Windows quand vous êtes prêt. Aucun redémarrage automatique demande par Atelier.') }
    $finalStatus=if ($warnings.Count) { 'needs_attention' } else { 'completed' }
    if ($warnings.Count) { $message='Préparation incomplète ou à vérifier. ' + ($warnings -join ' ') }
    Save-Maintenance $finalStatus 100 $message
    Finish-Maintenance
} catch {
    Save-Maintenance 'needs_attention' 100 ('Préparation à vérifier : ' + $_.Exception.Message)
    Finish-Maintenance
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
