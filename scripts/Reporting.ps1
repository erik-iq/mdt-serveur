
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
if (Test-Path (Join-Path $PSScriptRoot 'Timings.ps1')) { . (Join-Path $PSScriptRoot 'Timings.ps1') }
# Fonctions de rapport communes. Le chargement ne collecte rien et n’accède pas au réseau.
function Initialize-AtelierReportTrust {
    param([string]$DataPath)
    $path=Join-Path $DataPath 'trusted-root.cer'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    # Le même certificat public a été intégré et approuvé dans WinPE par l’administrateur.
    $certificate=New-Object Security.Cryptography.X509Certificates.X509Certificate2($path)
    if ($certificate.HasPrivateKey) { throw 'Le certificat de confiance doit être public, sans clé privée.' }
    $store=New-Object Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { $store.Add($certificate) } finally { $store.Close();$certificate.Dispose() }
}

function Send-AtelierWindowsProgress {
    param([string]$DataPath,[string]$Status,[int]$Percent,[string]$Message)
    $configuration = Join-Path $DataPath 'reporting.json'
    if (-not (Test-Path -LiteralPath $configuration)) { return }
    if ($script:nextReportingAttempt -and [DateTime]::UtcNow -lt $script:nextReportingAttempt -and $Status -eq 'running') { return }
    try {
        $config = Get-Content $configuration -Encoding UTF8 -Raw | ConvertFrom-Json
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{status=$Status;progress=$Percent;message=$Message} | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri ($config.server_url + '/api/windows/' + $config.id + '/progress') -Method Post -Headers @{Authorization=('Bearer ' + $config.token)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
    } catch {
        $script:nextReportingAttempt=[DateTime]::UtcNow.AddMinutes(1)
        # La transmission des rapports ne doit bloquer ni les logiciels ni la validation TLS.
        Add-Content -LiteralPath (Join-Path $DataPath 'reporting.log') -Value ((Get-Date).ToString('o') + ' Progression non transmise ; reprise au prochain état.') -Encoding UTF8
    }
}


# Les clés des anciens inventaires restent stables ; seuls leurs libellés changent.
function Get-AtelierReportLabel {
    param([string]$Value)
    $labels=@{
        'Modele'='Modèle';'Numéro de série'='Numéro de série';'Révision préparation'='Révision de préparation'
        'Numéro de série WinPE'='Numéro de série WinPE';'Reseau'='Réseau';'Édition Windows'='Édition Windows'
        'Démarrage rapide Windows'='Démarrage rapide Windows';'Profil déploye'='Profil déployé';'Garantie début / fin'='Garantie début / fin'
        'completed'='Terminé';'failed'='Échec';'needs_attention'='À vérifier';'running'='En cours';'manual'='Manuel'
        'skipped'='Non applicable';'unknown'='Inconnu';'passed'='Conforme';'not_tested'='Non testé'
        'reboot_pending'='Redémarrage prévu';'retry_pending'='Nouvelle tentative prévue';'deferred'='Reporté'
        'ACTIVE'='Activée';'NON ACTIVE'='Non activée';'INDETERMINE'='Indéterminé'
        'non_verifie'='Non vérifié';'active_confirmee_operateur'='Active, confirmée par le technicien'
        'expiree_confirmee_operateur'='Expirée, confirmée par le technicien'
    }
    if ($labels.ContainsKey($Value)) { return $labels[$Value] }
    return $Value
}

function Write-AtelierPdf {
    param([string]$Path,[string[]]$Lines)
    $wrapped = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        $clean = $line -replace '[\x00-\x1F]', ' '
        while ($clean.Length -gt 100) { $wrapped.Add($clean.Substring(0,100)); $clean=$clean.Substring(100) }
        $wrapped.Add($clean)
    }
    $encoding = [Text.Encoding]::GetEncoding(1252)
    $objects = New-Object 'Collections.Generic.List[string]'
    $objects.Add('<< /Type /Catalog /Pages 2 0 R >>'); $objects.Add('')
    $objects.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>')
    $pageIds = @(); $pages = [math]::Max(1,[math]::Ceiling($wrapped.Count/48))
    for ($page=0; $page -lt $pages; $page++) {
        $id = $objects.Count+1; $pageIds += "$id 0 R"
        $objects.Add(('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents {0} 0 R >>' -f ($id+1)))
        $commands = New-Object 'Collections.Generic.List[string]'
        $commands.Add('BT /F1 10 Tf 14 TL 40 800 Td')
        $pageLines = @($wrapped | Select-Object -Skip ($page*48) -First 48) + @('Page ' + ($page+1) + '/' + $pages)
        foreach ($line in $pageLines) {
            $escaped = $line.Replace('\','\\').Replace('(','\(').Replace(')','\)')
            $commands.Add('(' + $escaped + ') Tj T*')
        }
        $commands.Add('ET'); $content=$commands -join "`n"
        $objects.Add(('<< /Length {0} >>' -f $encoding.GetByteCount($content)) + "`nstream`n" + $content + "`nendstream")
    }
    $objects[1] = '<< /Type /Pages /Count ' + $pages + ' /Kids [' + ($pageIds -join ' ') + '] >>'
    $buffer=New-Object IO.MemoryStream
    try {
        $bytes=$encoding.GetBytes("%PDF-1.4`n"); $buffer.Write($bytes,0,$bytes.Length)
        $offsets=@(0L)
        for ($index=0; $index -lt $objects.Count; $index++) {
            $offsets += $buffer.Position
            $bytes=$encoding.GetBytes((($index+1).ToString() + " 0 obj`n" + $objects[$index] + "`nendobj`n"))
            $buffer.Write($bytes,0,$bytes.Length)
        }
        $start=$buffer.Position
        $xref="xref`n0 " + $offsets.Count + "`n0000000000 65535 f `n"
        foreach ($offset in $offsets | Select-Object -Skip 1) { $xref += ('{0:0000000000} 00000 n ' -f $offset) + "`n" }
        $xref += 'trailer' + "`n<< /Size " + $offsets.Count + " /Root 1 0 R >>`nstartxref`n" + $start + "`n%%EOF`n"
        $bytes=$encoding.GetBytes($xref); $buffer.Write($bytes,0,$bytes.Length)
        $temporary=$Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try { [IO.File]::WriteAllBytes($temporary,$buffer.ToArray()); Move-Item -LiteralPath $temporary -Destination $Path -Force }
        finally { if (Test-Path $temporary) { Remove-Item $temporary -Force } }
    } finally { $buffer.Dispose() }
}

function Complete-AtelierReport {
    param([string]$DataPath,[string]$ToolsPath='C:\IQ_')
    try {
        & (Join-Path $DataPath 'New-DeploymentReport.ps1') -DataPath $DataPath -OutputDirectory $ToolsPath
    } catch {
        Add-Content -LiteralPath (Join-Path $DataPath 'reporting.log') -Value ((Get-Date).ToString('o') + ' Rapport local à régénérer avec Generer-Rapport.cmd.') -Encoding UTF8
    }
}
