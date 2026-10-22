
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Envoyer les rapports HP détaillés avant de supprimer les identifiants temporaires du déploiement.
function Send-AtelierHpReports {
    param([string]$DataPath,[string]$ToolsPath,$Config)
    . (Join-Path $DataPath 'HP-Repository.ps1')
    Assert-AtelierHpTree $DataPath
    $resultPath=Join-Path $DataPath 'hpia-result.json'
    $result=if (Test-Path $resultPath) { Get-Content $resultPath -Encoding UTF8 -Raw } else { '{"status":"not_run","message":"Traitement HP non exécuté ; vérifier le rapport de préparation."}' }
    $state=$result | ConvertFrom-Json
    $files=New-Object 'Collections.Generic.List[object]'
    $files.Add(@{name='hpia-result.json';content=$result})
    $allowed=[IO.Path]::GetFullPath((Join-Path $ToolsPath 'Rapports\HPImageAssistant')).TrimEnd([char[]]'\/')
    if ($state.report_directory) {
        $root=[IO.Path]::GetFullPath([string]$state.report_directory).TrimEnd([char[]]'\/')
        if ($root -ne $allowed -and -not $root.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Dossier des rapports HP non autorisé.' }
        Assert-AtelierHpTree $root
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse)) {
            $relative=$file.FullName.Substring($root.Length+1).Replace('\','/')
            if ($relative -notmatch '^[A-Za-z0-9_. ()/-]+\.(json|xml|html|csv|log|txt)$') { continue }
            if ($file.Name -in @('reporting.json','personalization.json','data-runtime.json')) { continue }
            if ($file.Length -gt 16MB) { throw 'Un rapport HP depasse 16 Mo ; archive locale conservée.' }
            $content=[IO.File]::ReadAllText($file.FullName)
            # Mettre les déclarations XML/UTF-16 natives en cohérence avec l’envoi UTF-8.
            if ($file.Extension -eq '.xml') { $content=$content -replace '(?i)(<\?xml[^>]*encoding\s*=\s*["''])([^"'']+)(["''])','$1utf-8$3' }
            if ($file.Extension -eq '.html') { $content=$content -replace '(?i)(charset\s*=\s*["'']?)[A-Za-z0-9_-]+','$1utf-8' }
            $files.Add(@{name=$relative;content=$content})
        }
    }
    if ($files.Count -gt 1024) { throw 'Trop de fichiers dans les rapports HP.' }
    Add-Type -AssemblyName System.IO.Compression
    $archive=Join-Path $DataPath 'hp-reports-upload.zip'
    $stream=[IO.File]::Open($archive,[IO.FileMode]::Create)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
    $bytes=0L;$summaryHash=$null
    try {
        foreach ($file in @($files | Sort-Object name)) {
            $content=[string]$file.content
            if ($Config.token) { $content=$content.Replace([string]$Config.token,'[REDACTED]') }
            $encoded=[Text.Encoding]::UTF8.GetBytes($content);$bytes+=$encoded.Length
            if ($file.name -eq 'Rapport-Installation-HP.html') {
                $algorithm=[Security.Cryptography.SHA256]::Create()
                try { $summaryHash=([BitConverter]::ToString($algorithm.ComputeHash($encoded))).Replace('-','').ToLowerInvariant() } finally { $algorithm.Dispose() }
            }
            if ($encoded.Length -gt 16MB -or $bytes -gt 128MB) { throw 'Rapports HP trop volumineux ; nettoyage differe.' }
            $entry=$zip.CreateEntry($file.name,[IO.Compression.CompressionLevel]::Fastest)
            $entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
            $output=$entry.Open()
            try { $output.Write($encoded,0,$encoded.Length) } finally { $output.Dispose() }
        }
    } finally { $zip.Dispose();$stream.Dispose() }
    if ((Get-Item $archive).Length -gt 32MB) { throw 'Archive HP supérieure a 32 Mo ; copie locale conservée.' }
    $hash=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt=Join-Path $DataPath 'hp-reports-sent.json'
    if (Test-Path $receipt) {
        $saved=Get-Content $receipt -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($saved.deployment_id -eq $Config.id -and $saved.sha256 -eq $hash -and (-not $summaryHash -or $saved.summary_sha256 -eq $summaryHash)) { return $hash }
    }
    $reply=Invoke-RestMethod -Uri ($Config.server_url+'/api/windows/'+$Config.id+'/inventory/hp_reports') -Method Post -Headers @{Authorization=('Bearer '+$Config.token)} -ContentType 'application/zip' -InFile $archive -TimeoutSec 60
    if (-not $reply.accepted -or $reply.deployment_id -ne $Config.id -or $reply.sha256 -ne $hash) { throw 'Rapports HP non confirmés par .250.' }
    if ($summaryHash -and $reply.hp_summary.sha256 -ne $summaryHash) { throw 'Rapport HTML HP non confirmé par .250 ; fichiers locaux conservés.' }
    @{deployment_id=$Config.id;sha256=$hash;summary_sha256=$summaryHash;timestamp=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $receipt -Encoding UTF8
    return $hash
}
