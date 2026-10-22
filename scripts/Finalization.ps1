
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Fonctions seules. Ne pas supprimer le dossier privé sans confirmation du serveur.
function Assert-AtelierPrivateTree {
    param([string]$Path,[Collections.Generic.List[IO.FileStream]]$Handles)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $parent=$item
    while ($parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien refusé pour le nettoyage.' }
        $parent=$parent.Parent
    }
    $pending=New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($item.FullName)
    while ($pending.Count) {
        foreach ($child in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien refusé dans le dossier de travail.' }
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
            elseif ($null -ne $Handles) { $Handles.Add([IO.File]::Open($child.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Delete)) }
        }
    }
}
function Send-AtelierDiagnostics {
    param([string]$DataPath,$Config)
    Add-Type -AssemblyName System.IO.Compression
    $archivePath=Join-Path $DataPath 'diagnostics-upload.zip'
    $files=@('result.json','maintenance.json','progress.json','hpia-result.json','hp-repository-state.json','windows-kb-result.json','windows-update-result.json','first-logon.log','maintenance.log','reporting.log','cleanup.log')
    foreach ($key in @('vlc','reader','chrome','anydesk','hpia','lenovo_system_update','winget-preparation')) { $files+=@('software-logs/'+$key+'.log') }
    $timings=Join-Path $DataPath 'timings'
    if (Test-Path $timings) {
        foreach ($file in @(Get-ChildItem -LiteralPath $timings -File)) {
            if ($file.Name -match '^[a-z0-9_-]{1,80}\.json$') { $files+=@('timings/'+$file.Name) }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $DataPath -Filter 'kb-KB*.log' -File)) { if ($file.Name -match '^kb-KB[0-9]{6,9}\.log$') { $files+=@($file.Name) } }
    foreach ($name in @('result.json','maintenance.json')) { if (-not (Test-Path (Join-Path $DataPath $name) -PathType Leaf)) { throw 'Résultats obligatoires absents.' } }
    $stream=[IO.File]::Open($archivePath,[IO.FileMode]::Create)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $files) {
            $path=Join-Path $DataPath $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $content=if ($name.EndsWith('.log')) { (Get-Content -LiteralPath $path -Encoding UTF8 -Tail 2000) -join "`n" } else { Get-Content -LiteralPath $path -Encoding UTF8 -Raw }
            if ($name.EndsWith('.log') -and $content.Length -gt 262144) { $content=$content.Substring($content.Length-262144) }
            if ($Config.token) { $content=$content.Replace([string]$Config.token,'[REDACTED]') }
            $entry=$zip.CreateEntry($name)
            $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)))
            try { $writer.Write($content) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose();$stream.Dispose() }
    if ((Get-Item $archivePath).Length -gt 8MB) { throw 'Archive des journaux trop volumineuse ; nettoyage differe.' }
    $hash=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $response=Invoke-RestMethod -Uri ($Config.server_url+'/api/windows/'+$Config.id+'/inventory/diagnostics') -Method Post -Headers @{Authorization=('Bearer '+$Config.token)} -ContentType 'application/zip' -InFile $archivePath -TimeoutSec 60
    if (-not $response.accepted -or $response.deployment_id -ne $Config.id -or $response.sha256 -ne $hash) { throw 'Archive serveur non confirmée.' }
    return $hash
}
function Set-AtelierPermanentLinks {
    param([string]$ToolsPath,$Config)
    $url=[uri]$Config.server_url
    if ($url.Scheme -ne 'https' -or $url.UserInfo -or $url.Query -or $url.Fragment -or $url.AbsolutePath -ne '/') { throw 'Adresse serveur invalide pour les raccourcis IQ.' }
    $id=[guid]::Parse([string]$Config.id).ToString()
    foreach ($item in @(@{folder='Rapports';name='Generer-Rapport';view='report'},@{folder='Inventaire';name='Export-Inventaire';view='inventory'})) {
        $directory=Join-Path $ToolsPath $item.folder
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $target=$url.AbsoluteUri+'?deployment='+$id+'&view='+$item.view
        $text="param()`r`nStart-Process '"+$target.Replace("'","''")+"'`r`n"
        [IO.File]::WriteAllText((Join-Path $directory ($item.name+'.ps1')),$text,(New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $directory ($item.name+'.cmd')),('@echo off'+"`r`n"+'start "" "'+$target+'"'+"`r`n"),[Text.Encoding]::ASCII)
    }
    Add-Content -LiteralPath (Join-Path $ToolsPath 'Lisez-moi.txt') -Encoding UTF8 -Value 'Préparation archivee sur le serveur. Les commandes Rapports et Inventaire ouvrent désormais la fiche serveur. Les diagnostics IQ restent locaux et autonomes ; aucun jeton de déploiement n''est conservé.'
}
function Complete-AtelierLocalCleanup {
    param([string]$DataPath,[string]$ToolsPath)
    $safeToLog=$false
    $handles=New-Object 'Collections.Generic.List[IO.FileStream]'
    try {
        $expected=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'AtelierPXE'))
        if ([IO.Path]::GetFullPath($DataPath).TrimEnd([char[]]'\/') -ne $expected.TrimEnd([char[]]'\/')) { throw 'Nettoyage limite au dossier ProgramData\AtelierPXE.' }
        if ([IO.Path]::GetFullPath($ToolsPath).StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)) { throw 'Les outils IQ doivent être hors du dossier de travail.' }
        Assert-AtelierPrivateTree $DataPath
        $safeToLog=$true
        Assert-AtelierPrivateTree $ToolsPath
        $payload=Get-Content (Join-Path $DataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
        if (-not $payload.deployment.cleanup_after_reporting) { return $false }
        $config=Get-Content (Join-Path $DataPath 'reporting.json') -Encoding UTF8 -Raw | ConvertFrom-Json
        if ([string]$payload.deployment.id -ne [string]$config.id) { throw 'Identité de déploiement différente.' }
        $state=Get-Content (Join-Path $DataPath 'maintenance.json') -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($state.windows.source -in @('server_250','windows_update') -and $state.windows.status -eq 'installing') { return $false }
        if ($state.windows.source -eq 'windows_update' -and @($state.windows.passes | ForEach-Object {$_.updates} | Where-Object {$_.status -in @('installing','unknown')}).Count) {return $false}
        if ($state.status -notin @('completed','needs_attention')) { return $false }
        if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)^(winget|msiexec|HPImageAssistant|HpFirmwareUpdRec.*|HPBIOSUPDREC.*|HPBIOSUpdate.*)$' }).Count) { return $false }
        if ($state.reboot_required) {
            $boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15).LastBootUpTime
            if (-not $boot -or ([datetime]$boot).ToUniversalTime() -le [datetime]::Parse($state.timestamp).ToUniversalTime()) { return $false }
        }
        $workerPath=Join-Path $DataPath 'preparation-worker.json'
        if (Test-Path $workerPath) {
            $worker=Get-Content $workerPath -Encoding UTF8 -Raw | ConvertFrom-Json
            for ($attempt=0;$attempt -lt 4;$attempt++) {
                $active=Get-Process -Id ([int]$worker.pid) -ErrorAction SilentlyContinue
                if (-not $active -or $active.StartTime.ToUniversalTime() -ne ([datetime]$worker.started).ToUniversalTime()) { break }
                Start-Sleep -Milliseconds 500
            }
            if ($active -and $active.StartTime.ToUniversalTime() -eq ([datetime]$worker.started).ToUniversalTime()) { return $false }
        }
        $receiptPath=Get-AtelierIQFile $ToolsPath 'Rapports' 'Transmission-Rapport.json'
        $receipt=Get-Content $receiptPath -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($receipt.status -ne 'sent' -or $receipt.deployment_id -ne $config.id -or $receipt.report_sha256 -notmatch '^[a-f0-9]{64}$') { return $false }
        foreach ($name in @('result','maintenance')) {
            $hash=(Get-FileHash (Join-Path $DataPath ($name+'.json')) -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($receipt.($name+'_sha256') -ne $hash) { return $false }
        }
        $currentReport=(Get-Content (Get-AtelierIQFile $ToolsPath 'Rapports' 'Rapport-Deploiement.json') -Encoding UTF8 -Raw).TrimEnd([char[]]"`r`n")
        if ((Get-AtelierBytesHash ([Text.Encoding]::UTF8.GetBytes($currentReport))) -ne $receipt.report_sha256) { return $false }
        $proof=@{report=[string]$receipt.report_sha256}
        foreach ($kind in @('xml','csv')) {
            $proof[$kind]=(Get-FileHash -LiteralPath (Join-Path $DataPath ('Inventory\Inventaire-Technique.'+$kind)) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $proof.diagnostics=Send-AtelierDiagnostics $DataPath $config
        if ($payload.deployment.hp_repository -and 'hpia' -in @($payload.settings.winget_packages)) {
            . (Join-Path $DataPath 'HP-Reports.ps1')
            $proof.hp_reports=Send-AtelierHpReports -DataPath $DataPath -ToolsPath $ToolsPath -Config $config
        }
        $confirmation=Invoke-RestMethod -Uri ($config.server_url+'/api/windows/'+$config.id+'/cleanup-ready') -Method Post -Headers @{Authorization=('Bearer '+$config.token)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($proof|ConvertTo-Json))) -TimeoutSec 15
        if (-not $confirmation.cleanup_allowed -or $confirmation.deployment_id -ne $config.id) { return $false }
        foreach ($key in $proof.Keys) { if ($confirmation.hashes.$key -ne $proof[$key]) { return $false } }
        $previous=$null
        if ($payload.deployment.previous_payload_name) {
            $name=[string]$payload.deployment.previous_payload_name
            if ($name -notmatch '^AtelierPXE-Previous-[a-f0-9]{32}$') { throw 'Ancien dossier non autorisé.' }
            $previous=Join-Path (Split-Path $DataPath -Parent) $name
            if (Test-Path $previous) { Assert-AtelierPrivateTree $previous }
        }
        Set-AtelierPermanentLinks $ToolsPath $config
        # Garder des handles autorisant la suppression, mais bloquant les nouveaux lecteurs et rédacteurs.
        # Un fichier ouvert par un autre processus reporte le nettoyage avant toute modification des tâches.
        Assert-AtelierPrivateTree -Path $DataPath -Handles $handles
        if ($previous -and (Test-Path $previous)) { Assert-AtelierPrivateTree -Path $previous -Handles $handles }
        foreach ($task in @('AtelierPXE-Preparation','AtelierPXE-Tools','AtelierPXE-Maintenance')) {
            if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop }
        }
        foreach ($handle in $handles) { Remove-Item -LiteralPath $handle.Name -Force -ErrorAction Stop }
        # Windows termine DeleteFile lorsque le dernier handle partagé est fermé.
        # Fermer ces handles avant de retirer les dossiers désormais vides.
        foreach ($handle in $handles) { $handle.Dispose() }
        $handles.Clear()
        if ($previous -and (Test-Path $previous)) { Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction Stop }
        Remove-Item -LiteralPath $DataPath -Recurse -Force -ErrorAction Stop
        # Les identifiants restent seulement en mémoire jusqu’à la sortie de cet agent.
        try {
            $body=@{status=$state.status;progress=100;message='Préparation archivee sur le serveur. Dossier de travail AtelierPXE supprime du PC.'}|ConvertTo-Json
            Invoke-RestMethod -Uri ($config.server_url+'/api/windows/'+$config.id+'/progress') -Method Post -Headers @{Authorization=('Bearer '+$config.token)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
        } catch { }
        return $true
    } catch {
        foreach ($handle in $handles) { $handle.Dispose() }
        $handles.Clear()
        if ($safeToLog -and (Test-Path $DataPath)) { Add-Content -LiteralPath (Join-Path $DataPath 'cleanup.log') -Value ((Get-Date -Format o)+' Nettoyage differe : '+$_.Exception.Message) -Encoding UTF8 }
        return $false
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}
