#requires -Version 5.1
# Diagnostic WUA en lecture seule, avec fabrique injectable pour les tests.
function Invoke-AtelierUpdateScan {
    param(
        [ValidateSet('windows_update','configured')][string]$Source='windows_update',
        [ValidateRange(1,900)][int]$TimeoutSeconds=300,
        [int]$PollMilliseconds=2000,
        [scriptblock]$SessionFactory={New-Object -ComObject Microsoft.Update.Session},
        [scriptblock]$OnProgress={param($Message)}
    )
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $job=$null
    $result=[ordered]@{source=$Source;status='failed';criteria='IsInstalled=0 and IsHidden=0';result_code=$null;hresult=$null;count=0;previous_filter_count=0;updates=@();warnings=@();elapsed_seconds=0;message='Recherche non terminée.'}
    try {
        $session=& $SessionFactory
        $session.ClientApplicationID='Atelier PXE : diagnostic Windows Update'
        $searcher=$session.CreateUpdateSearcher()
        $searcher.Online=$true
        $searcher.ServerSelection=if ($Source -eq 'windows_update') {2} else {0}
        & $OnProgress ('Recherche '+$Source+' : logiciels, pilotes et mises à jour facultatives, limite '+$TimeoutSeconds+' secondes.') | Out-Null
        $job=$searcher.BeginSearch($result.criteria,$null,$null)
        while (-not $job.IsCompleted) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $job.RequestAbort()
                throw [TimeoutException]::new('Le délai de recherche est dépassé. Ce résultat ne signifie pas que Windows est à jour.')
            }
            & $OnProgress ('Recherche '+$Source+' en cours : '+[int]$clock.Elapsed.TotalSeconds+' secondes.') | Out-Null
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        $search=$searcher.EndSearch($job)
        $result.result_code=[int]$search.ResultCode
        foreach ($warning in @($search.Warnings)) {
            if ($warning) { $result.warnings+=@{message=[string]$warning.Message;hresult=('0x{0:X8}' -f ([long]$warning.HResult -band 4294967295))} }
        }
        foreach ($update in $search.Updates) {
            $entry=[ordered]@{
                title=[string]$update.Title;type=[int]$update.Type;browse_only=[bool]$update.BrowseOnly
                downloaded=[bool]$update.IsDownloaded;kb=@($update.KBArticleIDs | ForEach-Object {[string]$_})
                id=[string]$update.Identity.UpdateID;categories=@($update.Categories | ForEach-Object {[string]$_.Name})
            }
            $result.updates+=@($entry)
            if ($entry.type -eq 1 -and -not $entry.browse_only) { $result.previous_filter_count++ }
        }
        $result.count=@($result.updates).Count
        if ($result.result_code -eq 2) {
            $result.status=if ($result.count) {'updates_found'} else {'no_updates'}
            $result.message=if ($result.count) { [string]$result.count+' mise(s) à jour proposée(s) par cette recherche.' } else {'Recherche terminée sans mise à jour proposée par ce service.'}
        } else {
            $result.status='incomplete'
            $result.message='Recherche incomplète (résultat WUA '+$result.result_code+'). Aucun état à jour confirmé.'
        }
    } catch {
        $exception=$_.Exception
        while ($exception.InnerException) { $exception=$exception.InnerException }
        $result.status=if ($exception -is [TimeoutException]) {'timeout'} else {'failed'}
        $result.hresult=('0x{0:X8}' -f ([long]$exception.HResult -band 4294967295))
        $result.message=$exception.Message
    } finally {
        # CleanUp peut attendre une recherche encore active : ne le demander qu’après sa fin.
        if ($job -and $job.IsCompleted) { try { $job.CleanUp() } catch { } }
        $result.elapsed_seconds=[int]$clock.Elapsed.TotalSeconds
        $clock.Stop()
    }
    return [pscustomobject]$result
}
