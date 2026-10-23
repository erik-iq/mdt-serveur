#requires -Version 5.1
# Windows Update en ligne, avec état durable et reprise de la préparation Atelier.
function Invoke-AtelierAutomaticWindowsUpdate {
    param([string]$DataPath,[scriptblock]$OnProgress={param($Message)})
    . (Join-Path $DataPath 'WindowsUpdate-Diagnostic.ps1')
    . (Join-Path $DataPath 'WindowsUpdate-InstallTest.ps1')
    $path=Join-Path $DataPath 'windows-update-result.json'
    $boot=Get-AtelierHpBootIdentity
    $state=[pscustomobject]@{source='windows_update';revision='WU-AUTO-1';status='running';message='Windows Update automatique';timestamp='';boot_id=$boot;restarts=0;attempts=0;passes=@();active_pass=$null;verification=$null;count=0;titles=@();reboot_required=$false;windows=$null}
    if (Test-Path $path) {$state=Read-AtelierSharedUtf8File -Path $path | ConvertFrom-Json}
    if (-not $state.PSObject.Properties['recovery_checks']) {$state | Add-Member NoteProperty recovery_checks 0}
    function Save-AutomaticUpdate {
        $known=@($state.passes | ForEach-Object {$_.updates} | Where-Object {$_.status -in @('installed','installed_verified')})
        $state.count=$known.Count;$state.titles=@($known | ForEach-Object {$_.title})
        $state.timestamp=[DateTime]::UtcNow.ToString('o')
        Write-AtelierVerifiedUtf8File -Path $path -Content ($state | ConvertTo-Json -Depth 18) -NoBackup | Out-Null
    }
    function Publish-AutomaticUpdate([string]$Message) {
        $state.message=$Message;Save-AutomaticUpdate
        & $OnProgress $Message | Out-Null
    }
    function Set-AutomaticUpdateRestart([string]$Message) {
        if ($state.restarts -ge 6) {$state.status='needs_attention';$state.message='Limite de six redémarrages Windows Update atteinte.';Save-AutomaticUpdate;return}
        $state.status='reboot_pending';$state.boot_id=$boot;$state.restarts++;$state.reboot_required=$true
        $state.message=$Message;Save-AutomaticUpdate
    }
    function Set-AutomaticUpdateProofPending($Proof) {
        if (-not $Proof.pending) {$state.recovery_checks++}
        $state.status=if ($Proof.pending) {'retry_pending'} elseif ($state.recovery_checks -ge 6) {'needs_attention'} else {'installing'}
        $state.message=$Proof.message
        if ($state.recovery_checks -ge 6 -and -not $Proof.pending) {$state.message='Résultat Windows Update non confirmé après six vérifications. Rapports et fichiers conservés.'}
        Save-AutomaticUpdate
    }
    function Test-AutomaticUpdateRestartPending {
        return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    }
    if ($state.status -eq 'completed') {return $state}
    if ($state.status -eq 'needs_attention') {return $state}
    $uncertain=@($state.passes | Where-Object {@($_.updates | Where-Object {$_.status -in @('installing','unknown')}).Count})
    foreach ($pass in $uncertain) {
        $proof=Resolve-AtelierUpdatePass -Pass $pass
        if (-not $proof.confirmed) {
            Set-AutomaticUpdateProofPending $proof
            return $state
        }
        $state.status='running'
    }
    if ($state.status -eq 'installing' -and -not $state.active_pass) {
        $state.status='needs_attention';$state.message='Résultat Windows Update manquant et état de reprise incomplet.';Save-AutomaticUpdate;return $state
    }
    if ($state.status -eq 'reboot_pending' -and $state.boot_id -eq $boot) {return $state}
    if ($state.status -eq 'reboot_pending') {$state.reboot_required=$false;$state.status='running'}
    if ($state.active_pass) {
        # Un résultat d’installation absent après interruption ne devient jamais un succès.
        if (@($state.active_pass.updates | Where-Object {$_.status -eq 'installing'}).Count) {
            $proof=Resolve-AtelierUpdatePass -Pass $state.active_pass
            if (-not $proof.confirmed) {
                Set-AutomaticUpdateProofPending $proof
                return $state
            }
        }
        $state.passes+=@($state.active_pass);$state.active_pass=$null
    }
    if ($state.attempts -ge 12) {$state.status='needs_attention';$state.message='Limite des recherches Windows Update atteinte.';Save-AutomaticUpdate;return $state}
    $state.attempts++;$state.boot_id=$boot;$state.status='running'
    try {
        $os=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $state.windows=[pscustomobject]@{release=$os.DisplayVersion;build=$os.CurrentBuildNumber;ubr=$os.UBR;edition=$os.EditionID}
        Publish-AutomaticUpdate 'Recherche automatique des correctifs, de Defender et des pilotes Windows Update.'
        $check=Invoke-AtelierTestUpdatePass -VerifyOnly -OnProgress {param($Message);Publish-AutomaticUpdate $Message}
        $state.verification=$check
        if ($check.status -eq 'verified') {
            if (Test-AutomaticUpdateRestartPending) {Set-AutomaticUpdateRestart 'Redémarrage Windows nécessaire avant le contrôle final.'}
            else {$state.status='completed';$state.reboot_required=$false;$state.message='Windows Update terminé : recherche réussie sans correctif ni pilote restant proposé, aucun redémarrage Windows en attente.'}
        } elseif ($check.status -ne 'remaining') {
            $state.status='retry_pending';$state.message=('Recherche Windows Update à reprendre : '+$check.message)
        } elseif ($state.passes.Count -ge 5) {
            $state.status='needs_attention';$state.message='Cinq passes Windows Update effectuées. Des mises à jour restent proposées ; consulter le rapport.'
        } else {
            $state.active_pass=[pscustomobject]@{status='searching';updates=@()};Save-AutomaticUpdate
            $pass=Invoke-AtelierTestUpdatePass -OnProgress {param($Message);Publish-AutomaticUpdate $Message} -Checkpoint {
                param($Value);$state.active_pass=$Value;Save-AutomaticUpdate
            }
            $state.passes+=@($pass);$state.active_pass=$null
            $installed=@($state.passes | ForEach-Object {$_.updates} | Where-Object {$_.status -in @('installed','installed_verified')})
            $state.count=$installed.Count;$state.titles=@($installed | ForEach-Object {$_.title})
            if ($pass.status -in @('installed','reboot_required')) {Set-AutomaticUpdateRestart 'Mises à jour installées. Redémarrage automatique puis nouvelle recherche Windows Update.'}
            elseif ($pass.status -eq 'verified') {
                $state.verification=$pass
                if (Test-AutomaticUpdateRestartPending) {Set-AutomaticUpdateRestart 'Redémarrage requis avant validation Windows Update.'}
                else {$state.status='completed';$state.reboot_required=$false;$state.message=$pass.message}
            } elseif ($pass.status -eq 'unknown') {$state.status='installing';$state.message=$pass.message}
            else {$state.status='needs_attention';$state.message=$pass.message}
        }
    } catch {
        if (Test-AtelierFileSharingViolation $_.Exception) {
            $state.status='retry_pending';$state.message='État Windows Update temporairement occupé. Reprise automatique avec les checkpoints conservés.'
        } else {$state.status='needs_attention';$state.message=$_.Exception.Message}
    }
    Save-AutomaticUpdate
    return $state
}
