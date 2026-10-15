#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DataPath = 'C:\ProgramData\AtelierPXE', [string]$ToolsPath = 'C:\IQ_')
$ErrorActionPreference = 'Stop'
. (Join-Path $DataPath 'Unattend.ps1')
. (Join-Path $DataPath 'Updates.ps1')
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
    if (Test-Path (Join-Path $ToolsPath 'Transmission-Rapport.json')) {
        try { $sent=(Get-Content (Join-Path $ToolsPath 'Transmission-Rapport.json') -Raw | ConvertFrom-Json).status -eq 'sent' } catch { }
    }
    if (Test-Path $configuration) {
        try { $expired=[DateTime]::Parse((Get-Content $configuration -Raw | ConvertFrom-Json).expires) -lt [DateTime]::UtcNow } catch { }
    }
    # Keep only the bounded reporting retry alive while the server is offline.
    if (-not (Test-Path $configuration) -or $sent -or $expired) { Unregister-ScheduledTask -TaskName 'AtelierPXE-Maintenance' -Confirm:$false -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName 'AtelierPXE-Progress' -Confirm:$false -ErrorAction SilentlyContinue
}
function Schedule-Reboot {
    if ($state.reboots -ge 4) { throw 'Plus de quatre redemarrages demandes : intervention necessaire.' }
    $state.reboots++
    Save-Maintenance 'reboot_pending' 85 'Redemarrage automatique dans deux minutes ; la preparation reprendra ensuite.'
    & shutdown.exe /r /t 120 /d p:2:17 /c 'Atelier PXE : poursuite de la preparation Windows'
    if ($LASTEXITCODE -ne 0) { throw 'Impossible de programmer le redemarrage.' }
}
try {
    if (Test-Path $statePath) { $state = Get-Content $statePath -Raw | ConvertFrom-Json }
    if (-not $state.PSObject.Properties['windows_history']) { $state | Add-Member NoteProperty windows_history @() }
    if ($state.status -in @('completed','needs_attention')) { Finish-Maintenance; return }
    $payload = Get-Content (Join-Path $DataPath 'personalization.json') -Raw | ConvertFrom-Json
    $customization = Get-Content (Join-Path $DataPath 'result.json') -Raw | ConvertFrom-Json
    if ($customization.status -ne 'completed') { throw 'Les logiciels doivent etre termines avant les mises a jour.' }
    $state.attempts++
    if ($state.attempts -gt 6) { throw 'Limite de tentatives atteinte.' }
    if ($customization.restart_needed -and $state.reboots -eq 0) { Schedule-Reboot; return }
    if ($payload.settings.windows_update) {
        while ($state.passes -lt 5) {
            Save-Maintenance 'running' 80 ('Passe Windows Update ' + ($state.passes+1) + '/5 : recherche des mises a jour...')
            $script:lastUpdateWrite=[DateTime]::MinValue
            $state.windows = Invoke-AtelierWindowsUpdates -OnProgress {
                param($Detail)
                $script:updateDetail=$Detail
                if (([DateTime]::UtcNow-$script:lastUpdateWrite).TotalSeconds -lt 5) { return }
                $script:lastUpdateWrite=[DateTime]::UtcNow
                $phase=@{search='Recherche';download='Telechargement';install='Installation';installed='Installation terminee'}[$Detail.phase]
                $percent=if ($Detail.percent -ge 0) { ' - ' + $Detail.percent + ' % de cette etape' } else { ' - duree variable' }
                $title=[string]$Detail.title
                if ($title.Length -gt 700) { $title=$title.Substring(0,700) + '...' }
                Save-Maintenance 'running' 80 ($phase + ' Windows Update' + $percent + ' : ' + $title)
            }
            $state.windows_history=@($state.windows_history) + @(@{timestamp=[DateTime]::UtcNow.ToString('o');result=$state.windows})
            $state.passes++
            if ($state.windows.reboot_required) {
                Schedule-Reboot
                return
            }
            if ($state.windows.status -eq 'up_to_date') { break }
        }
        if ($state.windows.status -ne 'up_to_date') { throw 'Cinq passes effectuees ; des mises a jour peuvent rester necessaires.' }
    }
    if ($payload.settings.store_update) {
        Save-Maintenance 'running' 95 'Demande de mise a jour des applications Microsoft Store...'
        $state.store = Request-AtelierStoreUpdates
    }
    $licenseScript = Join-Path $ToolsPath 'Verifier-Licence.ps1'
    if (Test-Path $licenseScript) {
        try { & $licenseScript } catch { Add-Content -LiteralPath $logPath -Value 'Diagnostic de licence a relancer dans C:\IQ_.' -Encoding UTF8 }
    }
    $message = if ($payload.settings.store_update) { 'Windows et logiciels prepares. Actualisation Microsoft Store demandee ; consultez sa bibliotheque pour son avancement.' } else { 'Preparation de Windows et des logiciels terminee.' }
    Save-Maintenance 'completed' 100 $message
    Finish-Maintenance
} catch {
    if ($state.attempts -ge 6 -or $state.passes -ge 5 -or $state.reboots -ge 4) {
        Save-Maintenance 'needs_attention' 90 ('Intervention necessaire : ' + $_.Exception.Message)
        Finish-Maintenance
    } else { Save-Maintenance 'retry_pending' 80 ('Nouvelle tentative automatique dans 15 minutes : ' + $_.Exception.Message) }
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
