#requires -Version 5.1
# Les correctifs du serveur sont installés dans Windows avant HP et les logiciels.
function Invoke-AtelierKbFirst {
    param([string]$DataPath,[scriptblock]$OnProgress)
    . (Join-Path $DataPath 'Client-KBUpdates.ps1')
    $kb=Invoke-AtelierCachedWindowsUpdates -DataPath $DataPath -OnProgress $OnProgress
    $pending=$kb.status -notin @('completed','needs_attention')
    if ($kb.status -eq 'reboot_pending') {
        $boot=Get-AtelierKbBoot
        $path=Join-Path $DataPath 'kb-first-restart.json'
        $restart=[pscustomobject]@{boot_id='';restarts=0;requested_at=$null}
        if (Test-Path $path) { $restart=Read-AtelierSharedUtf8File -Path $path | ConvertFrom-Json }
        if ($restart.boot_id -eq $boot) { return [pscustomobject]@{pending=$true;kb=$kb} }
        if ($restart.restarts -ge 6) { throw 'Limite de six redémarrages KB atteinte. Rapports conservés.' }
        $payload=Get-Content (Join-Path $DataPath 'personalization.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($payload.settings.unattended) {
            $account=Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
            if (-not $account -or -not $account.Enabled) { throw 'Compte de reprise des KB indisponible.' }
            $winlogon='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-ItemProperty $winlogon DefaultUserName $account.Name
            Set-ItemProperty $winlogon DefaultDomainName $env:COMPUTERNAME
            Set-ItemProperty $winlogon DefaultPassword ''
            Set-ItemProperty $winlogon AutoAdminLogon '1'
            New-ItemProperty $winlogon AutoLogonCount -Value 1 -PropertyType DWord -Force | Out-Null
        }
        $restart.boot_id=$boot;$restart.restarts++;$restart.requested_at=[DateTime]::UtcNow.ToString('o')
        Write-AtelierVerifiedUtf8File -Path $path -Content ($restart | ConvertTo-Json) -NoBackup | Out-Null
        & shutdown.exe /r /t 60 /d p:2:17 /c 'Atelier PXE : correctifs KB installés. Reprise automatique avant HPIA et les logiciels.' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $restart.boot_id='';$restart.restarts--;$restart.requested_at=$null
            Write-AtelierVerifiedUtf8File -Path $path -Content ($restart | ConvertTo-Json) -NoBackup | Out-Null
            throw 'Windows a refusé le redémarrage des KB. La préparation reste en attente.'
        }
    }
    return [pscustomobject]@{pending=$pending;kb=$kb}
}
