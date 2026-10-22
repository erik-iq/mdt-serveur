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


# Réconcilier uniquement un résultat manquant, jamais effacer un échec natif enregistré.
function Resolve-AtelierUpdatePass {
    param(
        $Pass,
        [scriptblock]$SessionFactory={New-Object -ComObject Microsoft.Update.Session},
        [scriptblock]$CallbackFactory={New-AtelierUpdateSearchCallback},
        [ValidateRange(1,600)][int]$TimeoutSeconds=180,
        [int]$PollMilliseconds=1000
    )
    $proof=[ordered]@{confirmed=$false;pending=$false;message='Résultat non confirmé.';entries=@()}
    try {
        $session=& $SessionFactory
        $session.ClientApplicationID='Atelier PXE : vérification des installations Windows Update'
        if ($session.CreateUpdateInstaller().IsBusy) {
            $proof.pending=$true;$proof.message='Windows Update installe encore des mises à jour. Vérification automatique différée.'
            return [pscustomobject]$proof
        }
        $searcher=$session.CreateUpdateSearcher();$searcher.ServerSelection=2;$searcher.Online=$false
        $history=@()
        try {
            $count=[Math]::Min(500,[int]$searcher.GetTotalHistoryCount())
            if ($count -gt 0) {$history=@($searcher.QueryHistory(0,$count))}
        } catch { }
        foreach ($entry in @($Pass.updates)) {
            if ($entry.status -in @('installed','installed_verified')) {continue}
            if ($entry.status -eq 'failed' -or ($null -ne $entry.result_code -and [int]$entry.result_code -ne 2)) {
                $proof.entries+=@{id=$entry.id;confirmed=$false;message='Échec natif déjà enregistré ; aucune conversion en succès.'}
                continue
            }
            if ($entry.status -notin @('installing','unknown','planned','downloading','deferred')) {continue}
            $id=[guid]::Empty
            if (-not [guid]::TryParse([string]$entry.id,[ref]$id)) {throw 'Identifiant de mise à jour invalide pour la vérification.'}
            $start=[DateTime]::Parse($entry.started_utc).ToUniversalTime().AddSeconds(-5)
            $matches=@($history | Where-Object {
                $date=[datetime]$_.Date
                if ($date.Kind -eq [DateTimeKind]::Unspecified) {$date=[datetime]::SpecifyKind($date,[DateTimeKind]::Utc)}
                [string]$_.UpdateIdentity.UpdateID -eq $id.ToString() -and
                [int]$_.UpdateIdentity.RevisionNumber -eq [int]$entry.revision -and
                $date.ToUniversalTime() -ge $start -and $date.ToUniversalTime() -le [DateTime]::UtcNow.AddSeconds(5)
            } | Sort-Object Date -Descending)
            $last=$matches | Select-Object -First 1
            # Une DATE COM sans fuseau ne prouve pas la chronologie : vérifier alors l’état installé.
            $dated=$last -and ([datetime]$last.Date).Kind -ne [DateTimeKind]::Unspecified
            if ($dated -and [int]$last.Operation -eq 1 -and [int]$last.ResultCode -eq 2 -and ([long]$last.HResult -band 2147483648) -eq 0) {
                $entry.status='installed_verified';$entry.result_code=[int]$last.ResultCode;$entry.hresult=Get-AtelierUpdateHresult $last.HResult
                $entry | Add-Member NoteProperty verification_source 'windows_update_history' -Force
                $entry | Add-Member NoteProperty verified_utc ([DateTime]::UtcNow.ToString('o')) -Force
                $proof.entries+=@{id=$entry.id;confirmed=$true;source='windows_update_history';result_code=[int]$last.ResultCode;hresult=$entry.hresult}
                continue
            }
            if ($dated -and [int]$last.Operation -eq 1 -and [int]$last.ResultCode -in @(3,4,5)) {
                $entry.status='failed';$entry.result_code=[int]$last.ResultCode;$entry.hresult=Get-AtelierUpdateHresult $last.HResult
                $entry | Add-Member NoteProperty verification_source 'windows_update_history' -Force
                $proof.entries+=@{id=$entry.id;confirmed=$false;source='windows_update_history';result_code=[int]$last.ResultCode;hresult=$entry.hresult}
                continue
            }
            $job=$null
            try {
                $callback=& $CallbackFactory
                if (-not $callback) {throw 'Rappel COM de vérification absent.'}
                $job=$searcher.BeginSearch(("IsInstalled=1 and UpdateID='"+$id.ToString()+"'"),$callback,$null)
                if (-not $job) {throw 'Recherche de preuve installée indisponible.'}
                $clock=[Diagnostics.Stopwatch]::StartNew()
                while (-not $job.IsCompleted) {
                    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {$job.RequestAbort();throw 'Délai dépassé pendant la vérification installée.'}
                    Start-Sleep -Milliseconds $PollMilliseconds
                }
                $installed=$searcher.EndSearch($job)
                $found=@($installed.Updates | Where-Object {[string]$_.Identity.UpdateID -eq $id.ToString() -and [int]$_.Identity.RevisionNumber -ge [int]$entry.revision -and $_.IsInstalled})
                if ([int]$installed.ResultCode -eq 2 -and $found.Count) {
                    $entry.status='installed_verified'
                    # Le code d’installation reste absent : la preuve provient de l’état installé.
                    $entry | Add-Member NoteProperty verification_source 'installed_state' -Force
                    $entry | Add-Member NoteProperty verified_utc ([DateTime]::UtcNow.ToString('o')) -Force
                    $proof.entries+=@{id=$entry.id;confirmed=$true;source='installed_state';search_result_code=2}
                } else {$proof.entries+=@{id=$entry.id;confirmed=$false;source='installed_state';message='État installé non confirmé.'}}
            } finally {if ($job -and $job.IsCompleted) {try {$job.CleanUp()} catch {}}}
        }
        $proof.confirmed=@($Pass.updates).Count -gt 0 -and -not @($Pass.updates | Where-Object {$_.status -notin @('installed','installed_verified')}).Count
        $proof.message=if ($proof.confirmed) {'Résultats manquants vérifiés dans Windows Update, sans réinstallation.'} else {'Au moins une installation reste non confirmée. Aucun succès inventé.'}
        if ($proof.confirmed) {
            $Pass | Add-Member NoteProperty status_before_verification $Pass.status -Force
            $Pass.status='installed_verified';$Pass.message=$proof.message
        }
    } catch {$proof.message=$_.Exception.Message}
    $Pass | Add-Member NoteProperty reconciliation ([pscustomobject]$proof) -Force
    return [pscustomobject]$proof
}
