#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE', [string]$ToolsPath = 'C:\IQ_')
$ErrorActionPreference = 'Stop'
. (Join-Path $DataPath 'Unattend.ps1')
. (Join-Path $DataPath 'Updates.ps1')
. (Join-Path $PSScriptRoot 'IQ-Paths.ps1')
. (Join-Path $DataPath 'HP-ImageAssistant.ps1')
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
    if ($customization.status -ne 'completed') { throw 'Les logiciels doivent etre termines avant la finalisation du poste.' }
    $state.attempts++
    if ($state.attempts -gt 6) { throw 'Limite de tentatives atteinte.' }
    $state | Add-Member NoteProperty reboot_required ([bool]$customization.restart_needed -or [bool]$state.reboot_required -or $state.status -eq 'reboot_pending') -Force
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    # These legacy settings are deliberately ignored, even in an old payload.
    $state.windows=[pscustomobject]@{status='manual';count=0;reboot_required=$false;titles=@();message='Windows Update a lancer manuellement ; aucune recherche Atelier.'}
    $state.store=[pscustomobject]@{status='manual';completion_verified=$false;message='Microsoft Store a actualiser manuellement ; aucune recherche Atelier.'}
    Save-Maintenance 'running' 80 'Logiciels selectionnes prepares. Windows Update et Microsoft Store restent manuels.'
    $hp=[pscustomobject]@{status='skipped';message='HP Image Assistant non coche : installation et SoftPaq non demandes.';exit_code=$null;reboot_required=$false;timestamp=[DateTime]::UtcNow.ToString('o')}
    if ('hpia' -in @($payload.settings.winget_packages)) {
        $hp=Invoke-AtelierHpia -DataPath $DataPath -ToolsPath $ToolsPath -OnProgress {
            param($Message)
            $script:updateDetail=@{percent=-1}
            Save-Maintenance 'running' 85 $Message
        }
    }
    $script:updateDetail=$null
    $state | Add-Member NoteProperty hpia $hp -Force
    if ($hp.status -notin @('completed','skipped')) { $warnings.Add(('HP Image Assistant : '+$hp.message)) }
    if ($hp.reboot_required) { $state.reboot_required=$true }
    $licenseScript = Get-AtelierIQFile $ToolsPath 'Licence' 'Verifier-Licence.ps1'
    if (Test-Path $licenseScript) {
        try { & $licenseScript } catch { Add-Content -LiteralPath $logPath -Value 'Diagnostic de licence a relancer dans C:\IQ_.' -Encoding UTF8 }
    }
    $message = 'Preparation terminee. Windows Update et Microsoft Store a lancer manuellement.'
    if ($customization.software_status -eq 'needs_attention') { $warnings.Add('Certains logiciels WinGet necessitent une intervention. Consulter le rapport.') }
    if ($state.reboot_required) { $warnings.Add('Redemarrage necessaire : le lancer depuis le menu Windows quand vous etes pret. Aucun redemarrage automatique demande par Atelier.') }
    $finalStatus=if ($warnings.Count) { 'needs_attention' } else { 'completed' }
    if ($warnings.Count) { $message='Preparation terminee. ' + ($warnings -join ' ') }
    Save-Maintenance $finalStatus 100 $message
    Finish-Maintenance
} catch {
    Save-Maintenance 'needs_attention' 100 ('Preparation a verifier : ' + $_.Exception.Message)
    Finish-Maintenance
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
