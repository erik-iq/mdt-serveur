
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Moteur Windows Update ; les fabriques COM injectables permettent des tests sans modifier Windows.
function Invoke-AtelierWindowsUpdates {
    param(
        [scriptblock]$SessionFactory = { New-Object -ComObject Microsoft.Update.Session },
        [scriptblock]$CollectionFactory = { ,(New-Object -ComObject Microsoft.Update.UpdateColl) },
        [scriptblock]$OnProgress = { param($Detail) },
        [int]$PollMilliseconds = 2000,
        [ValidateRange(0,600)][int]$SearchTimeoutSeconds = 90
    )
    $session = & $SessionFactory
    $session.ClientApplicationID = 'Atelier PXE'
    $searcher = $session.CreateUpdateSearcher()
    $started=[DateTime]::UtcNow
    function Publish-UpdateProgress([string]$Phase,[int]$Percent,[string]$Title,[int]$Count=0) {
        & $OnProgress ([pscustomobject]@{phase=$Phase;percent=$Percent;title=$Title;count=$Count;elapsed_seconds=[int]([DateTime]::UtcNow-$started).TotalSeconds}) | Out-Null
    }
    function Wait-UpdateJob($Job,$Owner,[string]$Phase,$Updates) {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        try {
            while (-not $Job.IsCompleted) {
                if ($Phase -eq 'search' -and $SearchTimeoutSeconds -gt 0 -and $clock.Elapsed.TotalSeconds -ge $SearchTimeoutSeconds) {
                    $Job.RequestAbort()
                    throw [TimeoutException]::new(('Recherche Windows Update arrêtée après ' + $SearchTimeoutSeconds + ' secondes. Vérification reportée dans Windows Update.'))
                }
                $percent=-1; $title='Recherche dans le service configure (Windows Update / WSUS)'
                if ($Phase -ne 'search') {
                    $progress=$Job.GetProgress(); $percent=[int]$progress.PercentComplete
                    $index=[int]$progress.CurrentUpdateIndex
                    $title=if ($index -ge 0 -and $index -lt $Updates.Count) { [string]$Updates.Item($index).Title } else { 'Traitement des mises à jour sélectionnées' }
                }
                Publish-UpdateProgress $Phase $percent $title $Updates.Count
                Start-Sleep -Milliseconds $PollMilliseconds
            }
            switch ($Phase) {
                'search' { return $Owner.EndSearch($Job) }
                'download' { return $Owner.EndDownload($Job) }
                'install' { return $Owner.EndInstall($Job) }
            }
        } finally {
            # CleanUp attend les tâches COM inachevées : ne jamais réintroduire une attente illimitée.
            if ($Job.IsCompleted) { $Job.CleanUp() }
            $clock.Stop()
        }
    }
    # Respecter le service ou WSUS configuré. Exclure les pilotes et correctifs facultatifs.
    $criteria="IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0"
    if (-not $searcher.PSObject.Methods['BeginSearch'] -and $SearchTimeoutSeconds -gt 0) { throw 'Recherche asynchrone indisponible ; vérification Windows Update reportée.' }
    Publish-UpdateProgress 'search' -1 ('Recherche des mises à jour nécessaires ; limite ' + $SearchTimeoutSeconds + ' secondes.')
    $search = if ($searcher.PSObject.Methods['BeginSearch']) { Wait-UpdateJob ($searcher.BeginSearch($criteria,$null,$null)) $searcher 'search' @() } else { $searcher.Search($criteria) }
    if ([int]$search.ResultCode -ne 2) { throw ('Recherche Windows Update incomplète (résultat ' + $search.ResultCode + ').') }
    $updates = & $CollectionFactory
    $titles = @()
    foreach ($update in $search.Updates) {
        if ($update.InstallationBehavior.CanRequestUserInput) { throw 'Une mise à jour exige une intervention utilisateur.' }
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        $updates.Add($update) | Out-Null
        $titles += [string]$update.Title
    }
    if ($updates.Count -eq 0) { return [pscustomobject]@{status='up_to_date';count=0;reboot_required=$false;titles=@()} }
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    Publish-UpdateProgress 'download' 0 ($titles -join ' ; ') $updates.Count
    $download = if ($downloader.PSObject.Methods['BeginDownload']) { Wait-UpdateJob ($downloader.BeginDownload($null,$null,$null)) $downloader 'download' $updates } else { $downloader.Download() }
    if ([int]$download.ResultCode -ne 2) { throw ('Téléchargement Windows Update incomplet (résultat ' + $download.ResultCode + ', HRESULT ' + $download.HResult + ').') }
    $installer = $session.CreateUpdateInstaller()
    if ($installer.IsBusy) { throw 'Windows Update effectue déjà une installation. Attendre sa fin avant une nouvelle passe.' }
    if ($installer.RebootRequiredBeforeInstallation) {
        return [pscustomobject]@{status='reboot_required';count=0;reboot_required=$true;titles=@()}
    }
    $installer.Updates = $updates
    $installer.AllowSourcePrompts = $false
    $installer.ForceQuiet = $true
    Publish-UpdateProgress 'install' 0 ($titles -join ' ; ') $updates.Count
    $result = if ($installer.PSObject.Methods['BeginInstall']) { Wait-UpdateJob ($installer.BeginInstall($null,$null,$null)) $installer 'install' $updates } else { $installer.Install() }
    if ([int]$result.ResultCode -ne 2) { throw ('Installation Windows Update incomplète (résultat ' + $result.ResultCode + ', HRESULT ' + $result.HResult + ').') }
    for ($index=0; $index -lt $updates.Count; $index++) {
        $individual=$result.GetUpdateResult($index)
        if ([int]$individual.ResultCode -ne 2) { throw ('Échec de ' + $titles[$index] + ' (HRESULT ' + $individual.HResult + ').') }
    }
    Publish-UpdateProgress 'installed' 100 ($titles -join ' ; ') $updates.Count
    return [pscustomobject]@{status='installed';count=$updates.Count;reboot_required=[bool]$result.RebootRequired;titles=@($titles)}
}

function Request-AtelierStoreUpdates {
    # Le pont MDM exige SYSTEM et demande une analyse ; il ne fournit pas
    # de résultat global fiable d’achèvement pour les installations du Store.
    $manager = @(Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01')
    if ($manager.Count -ne 1) { throw 'Service de mise à jour Microsoft Store indisponible.' }
    $result = Invoke-CimMethod -InputObject $manager[0] -MethodName 'UpdateScanMethod'
    if ([int]$result.ReturnValue -ne 0) { throw 'La demande de mise à jour Microsoft Store a échoué.' }
    return [pscustomobject]@{status='requested';completion_verified=$false;message='Actualisation Microsoft Store demandée ; son achèvement reste gere par Windows.'}
}

function Disable-AtelierAutoLogon {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $path -Name AutoAdminLogon -Value '0'
    foreach ($name in @('DefaultPassword','AutoLogonCount')) { Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue }
}
