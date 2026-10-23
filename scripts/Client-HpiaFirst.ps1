#requires -Version 5.1
# HPIA est préparé et exécuté avant les autres logiciels dans le premier compte élevé.
function Invoke-AtelierHpiaFirst {
    param([string]$DataPath,[string]$ToolsPath,[scriptblock]$OnProgress)
    . (Join-Path $DataPath 'Client-Software.ps1')
    . (Join-Path $DataPath 'HP-ImageAssistant.ps1')
    $payload=Get-Content (Join-Path $DataPath 'personalization.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry=@(Install-AtelierClientSoftware -DataPath $DataPath -Packages @('hpia') -OnProgress $OnProgress) | Select-Object -First 1
    if (-not $entry) { $entry=[pscustomobject]@{id='hpia';name='HP Image Assistant';status='failed';exit_code=-1;reason='Résultat de préparation HPIA absent.'} }
    if ($entry.status -ne 'completed') {
        $hp=[pscustomobject]@{status='needs_attention';message=('Préparation HPIA : '+$entry.reason);exit_code=$entry.exit_code;reboot_required=$false;timestamp=[DateTime]::UtcNow.ToString('o')}
        Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'hpia-result.json') -Content ($hp | ConvertTo-Json -Depth 14) -NoBackup | Out-Null
        return [pscustomobject]@{pending=$false;application=$entry;hp=$hp}
    }
    $tools=@();if ($entry.tool) { $tools=@($entry.tool) }
    Write-AtelierVerifiedUtf8File -Path (Join-Path $DataPath 'ready-tools.json') -Content (ConvertTo-Json -InputObject $tools -Depth 6) -NoBackup | Out-Null
    # Préparer la connexion de reprise avant HP, qui peut lui-même lancer un flash BIOS.
    $manufacturer=[string](Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15).Manufacturer
    if ($payload.deployment.allow_bios_restart -and $payload.settings.unattended -and $manufacturer -match '(?i)^(HP|Hewlett[ -]Packard)(\b|\s)') {
        $account=Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
        if (-not $account -or -not $account.Enabled) { throw 'Compte de reprise HP indisponible.' }
        $winlogon='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $winlogon DefaultUserName $account.Name
        Set-ItemProperty $winlogon DefaultDomainName $env:COMPUTERNAME
        Set-ItemProperty $winlogon DefaultPassword ''
        Set-ItemProperty $winlogon AutoAdminLogon '1'
        New-ItemProperty $winlogon AutoLogonCount -Value 1 -PropertyType DWord -Force | Out-Null
    }
    # Capturer le destinataire : le moteur possède aussi un paramètre OnProgress.
    $hpFirstProgressSink=$OnProgress
    $hpFirstProgressRelay={
        param($Message)
        & $hpFirstProgressSink 10 $Message | Out-Null
    }.GetNewClosure()
    $hp=Invoke-AtelierHpia -DataPath $DataPath -ToolsPath $ToolsPath -OnProgress $hpFirstProgressRelay
    $pending=$hp.status -in @('running','reboot_pending','retry_pending')
    if ($hp.status -eq 'reboot_pending' -and $payload.deployment.allow_bios_restart) { Request-AtelierHpBiosRestart -DataPath $DataPath }
    return [pscustomobject]@{pending=$pending;application=$entry;hp=$hp}
}
