#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE', [string]$ToolsPath = 'C:\IQ_')
$ErrorActionPreference = 'Stop'
. (Join-Path $DataPath 'Unattend.ps1')
. (Join-Path $DataPath 'Updates.ps1')
. (Join-Path $PSScriptRoot 'IQ-Paths.ps1')
if (Test-Path (Join-Path $DataPath 'Reporting.ps1')) { . (Join-Path $DataPath 'Reporting.ps1') }
$statePath = Join-Path $DataPath 'maintenance.json'
$logPath = Join-Path $DataPath 'maintenance.log'
$mutex = New-Object Threading.Mutex($false,'Global\AtelierPXE-Maintenance')
$owned = $mutex.WaitOne(0)
if (-not $owned) { $mutex.Dispose(); exit 0 }
$state = [pscustomobject]@{status='running';attempts=0;passes=0;reboots=0;windows=$null;store=$null;message='Preparation des mises a jour';timestamp=''}
function Save-Maintenance([string]$Status,[int]$Percent,[string]$Message) {
    $state.status=$Status; $state.message=$Message; $state.timestamp=[DateTime]::UtcNow.ToString('o')
    Write-AtelierVerifiedUtf8File -Path $statePath -Content ($state | ConvertTo-Json -Depth 8) -NoBackup | Out-Null
    Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'progress.json') -Content (@{status=$Status;progress=$Percent;message=$Message;timestamp=$state.timestamp;detail=$script:updateDetail} | ConvertTo-Json -Depth 5) -NoBackup | Out-Null
    Add-Content -LiteralPath $logPath -Value ($state.timestamp + ' ' + $Message) -Encoding UTF8
    if (Get-Command Send-AtelierWindowsProgress -ErrorAction SilentlyContinue) { Send-AtelierWindowsProgress $DataPath $Status $Percent $Message }
}
function Finish-Maintenance {
    Disable-AtelierAutoLogon
    if (Get-Command Complete-AtelierReport -ErrorAction SilentlyContinue) { Complete-AtelierReport $DataPath $ToolsPath }
    $configuration=Join-Path $DataPath 'reporting.json'
    $sent=$false; $expired=$false
    $receipt=Get-AtelierIQFile $ToolsPath 'Rapports' 'Transmission-Rapport.json'
    if (Test-Path $receipt) {
        try { $sent=(Get-Content $receipt -Encoding UTF8 -Raw | ConvertFrom-Json).status -eq 'sent' } catch { }
    }
    if (Test-Path $configuration) {
        try { $expired=[DateTime]::Parse((Get-Content $configuration -Encoding UTF8 -Raw | ConvertFrom-Json).expires) -lt [DateTime]::UtcNow } catch { }
    }
    # Keep only the bounded reporting retry alive while the server is offline.
    if (-not (Test-Path $configuration) -or $sent -or $expired) { Unregister-ScheduledTask -TaskName 'AtelierPXE-Maintenance' -Confirm:$false -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName 'AtelierPXE-Progress' -Confirm:$false -ErrorAction SilentlyContinue
}

try {
    if (Test-Path $statePath) { $state = Get-Content $statePath -Encoding UTF8 -Raw | ConvertFrom-Json }
    if (-not $state.PSObject.Properties['windows_history']) { $state | Add-Member NoteProperty windows_history @() }
    if ($state.status -in @('completed','needs_attention')) { Finish-Maintenance; return }
    $payload = Get-Content (Join-Path $DataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    $customization = Get-Content (Join-Path $DataPath 'result.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($customization.status -ne 'completed') { throw 'Les logiciels doivent etre termines avant les mises a jour.' }
    $state.attempts++
    if ($state.attempts -gt 6) { throw 'Limite de tentatives atteinte.' }
    $state | Add-Member NoteProperty reboot_required ([bool]$customization.restart_needed) -Force
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    if ($payload.settings.windows_update) {
        if ($state.passes -lt 1) {
            Save-Maintenance 'running' 80 'Windows Update : une seule passe ; recherche limitee a 90 secondes.'
            $script:lastUpdateWrite=[DateTime]::MinValue
            try { $state.windows = Invoke-AtelierWindowsUpdates -SearchTimeoutSeconds 90 -OnProgress {
                param($Detail)
                $script:updateDetail=$Detail
                if (([DateTime]::UtcNow-$script:lastUpdateWrite).TotalSeconds -lt 5) { return }
                $script:lastUpdateWrite=[DateTime]::UtcNow
                $phase=@{search='Recherche';download='Telechargement';install='Installation';installed='Installation terminee'}[$Detail.phase]
                $percent=if ($Detail.percent -ge 0) { ' - ' + $Detail.percent + ' % de cette etape' } else { ' - ' + $Detail.elapsed_seconds + '/90 secondes' }
                $title=[string]$Detail.title
                if ($title.Length -gt 700) { $title=$title.Substring(0,700) + '...' }
                Save-Maintenance 'running' 80 ($phase + ' Windows Update' + $percent + ' : ' + $title)
            } } catch {
                $state.windows=[pscustomobject]@{status='deferred';count=0;reboot_required=$false;titles=@();message=$_.Exception.Message}
                $warnings.Add(('Windows Update non verifie : ' + $_.Exception.Message))
            }
            $state.windows_history=@($state.windows_history) + @(@{timestamp=[DateTime]::UtcNow.ToString('o');result=$state.windows})
            $state.passes++
            if ($state.windows.reboot_required) {
                $state.reboot_required=$true
            }
        }
        if ($state.windows.status -eq 'up_to_date') { Save-Maintenance 'running' 94 'Aucune mise a jour necessaire trouvee. Passage a la suite.' }
        elseif ($state.windows.status -eq 'installed') { Save-Maintenance 'running' 94 'Mises a jour de cette passe installees. Les prochaines recherches seront gerees par Windows.' }
        elseif ($state.windows.status -eq 'deferred' -and $warnings.Count -eq 0) { $warnings.Add('Windows Update reporte ; consulter Parametres > Windows Update.') }
        elseif ($state.windows.status -notin @('installed','up_to_date','reboot_required','deferred')) { $warnings.Add('Etat Windows Update precedent incomplet ; verification a reprendre dans Parametres.') }
    }
    if ($payload.settings.store_update) {
        Save-Maintenance 'running' 95 'Demande de mise a jour des applications Microsoft Store...'
        try { $state.store = Request-AtelierStoreUpdates }
        catch { $warnings.Add(('Actualisation Store non demandee : ' + $_.Exception.Message)) }
    }
    $licenseScript = Get-AtelierIQFile $ToolsPath 'Licence' 'Verifier-Licence.ps1'
    if (Test-Path $licenseScript) {
        try { & $licenseScript } catch { Add-Content -LiteralPath $logPath -Value 'Diagnostic de licence a relancer dans C:\IQ_.' -Encoding UTF8 }
    }
    $message = if ($payload.settings.store_update) { 'Windows et logiciels prepares. Actualisation Microsoft Store demandee ; consultez sa bibliotheque pour son avancement.' } else { 'Preparation de Windows et des logiciels terminee.' }
    if ($customization.software_status -eq 'needs_attention') { $warnings.Add('Certains logiciels WinGet necessitent une intervention. Consulter le rapport.') }
    if ($state.reboot_required) { $warnings.Add('Redemarrage necessaire : le lancer depuis le menu Windows quand vous etes pret. Aucune nouvelle recherche imposee.') }
    $finalStatus=if ($warnings.Count) { 'needs_attention' } else { 'completed' }
    if ($warnings.Count) { $message='Preparation terminee. ' + ($warnings -join ' ') }
    Save-Maintenance $finalStatus 100 $message
    Finish-Maintenance
} catch {
    Save-Maintenance 'needs_attention' 100 ('Preparation a verifier : ' + $_.Exception.Message)
    Finish-Maintenance
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
