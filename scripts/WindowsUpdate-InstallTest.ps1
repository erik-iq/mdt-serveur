#requires -Version 5.1
# Moteur partagé par la préparation Windows automatique et le kit de test.
function ConvertTo-AtelierUpdateTitle([string]$Title) {
    return $Title.Replace([char]0x2013,'-').Replace([char]0x2014,'-')
}
function Get-AtelierUpdateHresult($Value) {return ('0x{0:X8}' -f ([long]$Value -band 4294967295))}
function Get-AtelierTestUpdateResumeAction($State,[string]$Boot) {
    if ($State.status -in @('completed','needs_attention')) {return 'finished'}
    if ($State.status -eq 'restart_pending' -and $State.boot -eq $Boot) {return 'wait_for_restart'}
    if ($State.status -eq 'running' -and $State.active_pass) {return 'verify_interrupted'}
    return 'continue'
}
function Invoke-AtelierTestUpdatePass {
    param(
        [scriptblock]$SessionFactory={New-Object -ComObject Microsoft.Update.Session},
        [scriptblock]$CollectionFactory={,(New-Object -ComObject Microsoft.Update.UpdateColl)},
        [scriptblock]$CallbackFactory={New-AtelierUpdateSearchCallback},
        [scriptblock]$OnProgress={param($Message)},
        [scriptblock]$Checkpoint={param($Value)},
        [int]$PollMilliseconds=2000,
        [ValidateRange(1,3600)][int]$SearchTimeoutSeconds=300,
        [ValidateRange(1,7200)][int]$OperationTimeoutSeconds=3600,
        [switch]$VerifyOnly
    )
    $result=[ordered]@{status='failed';message='Passe non terminée.';reboot_required=$false;updates=@();excluded=@();remaining=@();error_stage=$null;hresult=$null}
    $stage='session_creation'
    function Wait-TestOperation($Job,$Owner,[string]$Phase) {
        if ($null -eq $Job) {throw 'Aucune opération WUA retournée.'}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        try {
            while (-not $Job.IsCompleted) {
                $limit=if ($Phase -eq 'search') {$SearchTimeoutSeconds} else {$OperationTimeoutSeconds}
                if ($clock.Elapsed.TotalSeconds -ge $limit) {
                    # Une installation sans code de retour demeure incertaine.
                    if ($Phase -ne 'install') {$Job.RequestAbort()}
                    throw [TimeoutException]::new('Délai dépassé pendant '+$Phase+'. Aucun succès confirmé.')
                }
                $percent=''
                if ($Phase -ne 'search') {try {$percent=' '+[int]$Job.GetProgress().PercentComplete+' %'} catch {}}
                & $OnProgress ($Phase+$percent+' : '+[int]$clock.Elapsed.TotalSeconds+' secondes.') | Out-Null
                Start-Sleep -Milliseconds $PollMilliseconds
            }
            switch ($Phase) {
                'search' {return $Owner.EndSearch($Job)}
                'download' {return $Owner.EndDownload($Job)}
                'install' {return $Owner.EndInstall($Job)}
            }
        } finally {if ($Job.IsCompleted) {try {$Job.CleanUp()} catch {}}}
    }
    try {
        $session=& $SessionFactory
        $session.ClientApplicationID='Atelier PXE : installation Windows Update'
        $searcher=$session.CreateUpdateSearcher();$searcher.Online=$true;$searcher.ServerSelection=2
        $completed=& $CallbackFactory;$progress=& $CallbackFactory
        if ($null -eq $completed -or $null -eq $progress) {throw 'Rappels COM Windows Update absents.'}
        $stage='search'
        & $OnProgress 'Recherche des mises à jour applicables dans Windows Update.' | Out-Null
        $search=Wait-TestOperation ($searcher.BeginSearch('IsInstalled=0 and IsHidden=0',$completed,$null)) $searcher 'search'
        if ([int]$search.ResultCode -ne 2) {throw ('Recherche incomplète, code WUA '+$search.ResultCode)}
        $selected=@()
        foreach ($update in $search.Updates) {
            $title=ConvertTo-AtelierUpdateTitle $update.Title
            $categories=@($update.Categories)
            if (@($categories | Where-Object {$_.CategoryID -eq '3689bdc8-b205-4af4-8d4a-a63924c5e9d5' -or $_.Name -match '^(Upgrades|Mises à niveau)$'}).Count) {
                $result.excluded+=@{id=[string]$update.Identity.UpdateID;title=$title;reason='Changement de version Windows exclu.'}
                continue
            }
            $selected+=@($update)
            $result.remaining+=@{id=[string]$update.Identity.UpdateID;title=$title;type=[int]$update.Type}
        }
        & $Checkpoint ([pscustomobject]$result) | Out-Null
        if (-not $selected.Count) {
            $result.status='verified';$result.message='Recherche réussie : aucun correctif ni pilote restant proposé par Windows Update.'
            return [pscustomobject]$result
        }
        if ($VerifyOnly) {$result.status='remaining';$result.message='Des mises à jour restent proposées.';return [pscustomobject]$result}
        $installer=$session.CreateUpdateInstaller()
        if ($installer.IsBusy) {throw 'Une autre installation Windows Update est déjà active. Aucun installateur interrompu.'}
        if ($installer.RebootRequiredBeforeInstallation) {
            $result.status='reboot_required';$result.reboot_required=$true;$result.message='Windows demande un redémarrage avant installation.'
            return [pscustomobject]$result
        }
        # Correctifs logiciels avant pilotes ; firmware en dernier si le titre le précise.
        $selected=@($selected | Sort-Object @{Expression={if ($_.Title -match '(?i)(firmware|BIOS)') {2} elseif ([int]$_.Type -eq 2) {1} else {0}}})
        foreach ($update in $selected) {
            $entry=[pscustomobject]@{id=[string]$update.Identity.UpdateID;revision=[int]$update.Identity.RevisionNumber;title=(ConvertTo-AtelierUpdateTitle $update.Title);type=[int]$update.Type;status='planned';started_utc=[DateTime]::UtcNow.ToString('o');result_code=$null;hresult=$null;reboot_required=$false}
            $result.updates+=@($entry)
            $stage='selection'
            # Cet indicateur décrit une possibilité, pas une obligation. Tenter ForceQuiet
            # et conserver le vrai résultat natif si le pilote refuse le mode silencieux.
            $entry | Add-Member NoteProperty can_request_user_input ([bool]$update.InstallationBehavior.CanRequestUserInput)
            if (-not $update.EulaAccepted) {$update.AcceptEula()}
            $collection=& $CollectionFactory
            $collection.Add($update) | Out-Null
            if (-not $update.IsDownloaded) {
                $stage='download';$entry.status='downloading'
                & $Checkpoint ([pscustomobject]$result) | Out-Null
                & $OnProgress ('Téléchargement : '+$entry.title) | Out-Null
                $downloader=$session.CreateUpdateDownloader();$downloader.Updates=$collection
                $download=Wait-TestOperation ($downloader.BeginDownload($progress,$completed,$null)) $downloader 'download'
                $part=$download.GetUpdateResult(0)
                if ([int]$download.ResultCode -ne 2 -or [int]$part.ResultCode -ne 2) {
                    $entry.result_code=[int]$part.ResultCode;$entry.hresult=Get-AtelierUpdateHresult $part.HResult;$entry.status='failed'
                    throw ('Téléchargement incomplet : '+$entry.title+' ('+$entry.hresult+')')
                }
            }
            $stage='install';$entry.status='installing'
            & $Checkpoint ([pscustomobject]$result) | Out-Null
            & $OnProgress ('Installation : '+$entry.title) | Out-Null
            $installer=$session.CreateUpdateInstaller()
            if ($installer.IsBusy) {throw 'Une autre installation Windows Update est devenue active.'}
            if ($installer.RebootRequiredBeforeInstallation) {
                $entry.status='deferred';$result.status='reboot_required';$result.reboot_required=$true
                $result.message='Redémarrage nécessaire avant la mise à jour suivante.'
                & $Checkpoint ([pscustomobject]$result) | Out-Null
                return [pscustomobject]$result
            }
            $installer.Updates=$collection;$installer.AllowSourcePrompts=$false;$installer.ForceQuiet=$true
            $native=Wait-TestOperation ($installer.BeginInstall($progress,$completed,$null)) $installer 'install'
            $part=$native.GetUpdateResult(0)
            $entry.result_code=[int]$part.ResultCode;$entry.hresult=Get-AtelierUpdateHresult $part.HResult
            $entry.reboot_required=[bool]$native.RebootRequired -or [bool]$part.RebootRequired
            $entry.status=if ([int]$native.ResultCode -eq 2 -and $entry.result_code -eq 2) {'installed'} else {'failed'}
            & $Checkpoint ([pscustomobject]$result) | Out-Null
            if ($entry.status -ne 'installed') {throw ('Installation en échec : '+$entry.title+' ('+$entry.hresult+')')}
            if ($entry.reboot_required) {
                $result.status='reboot_required';$result.reboot_required=$true;$result.message='Installation réussie, redémarrage demandé par Windows.'
                return [pscustomobject]$result
            }
        }
        $result.status='installed';$result.reboot_required=$true;$result.message='Passe installée. Redémarrage puis nouvelle recherche nécessaires.'
    } catch {
        $result.error_stage=$stage
        $exception=$_.Exception;while ($exception.InnerException) {$exception=$exception.InnerException}
        $result.hresult=Get-AtelierUpdateHresult $exception.HResult;$result.message=$exception.Message
        $result.status=if ($stage -eq 'install' -and $result.updates.Count -and $result.updates[-1].status -eq 'installing') {'unknown'} else {'failed'}
    }
    & $Checkpoint ([pscustomobject]$result) | Out-Null
    return [pscustomobject]$result
}
