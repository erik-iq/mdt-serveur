
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Validation du YAML limité à un installateur, produit par winget download.
# Ceci n’est pas un interpréteur YAML général ; aucun code du manifeste n’est exécuté.
function Get-AtelierManifestScalar {
    param([string]$Text,[string]$Name)
    $matches=[regex]::Matches($Text,'(?m)^\s*(?:-\s*)?' + [regex]::Escape($Name) + ':\s*([^\r\n]+)\s*$')
    if ($matches.Count -ne 1) { throw ('Manifeste exporte ambigu : ' + $Name) }
    $value=$matches[0].Groups[1].Value.Trim()
    if ($value -match '^"([^"\\]*)"$' -or $value -match "^'([^']*)'$") { return $Matches[1] }
    if ($value -match '^[^#\x00-\x1F\s\[\]{}&*!|>]+$') { return $value }
    throw ('Valeur de manifeste non prise en charge : ' + $Name)
}

function Get-AtelierDownloadedInstaller {
    param([string]$Directory,$Source)
    $candidates=@()
    foreach ($manifest in @(Get-ChildItem -LiteralPath $Directory -Filter '*.yaml' -File)) {
        $text=Get-Content -LiteralPath $manifest.FullName -Encoding UTF8 -Raw
        if ((Get-AtelierManifestScalar $text 'PackageIdentifier') -ne $Source.winget_id) { continue }
        $path=[IO.Path]::ChangeExtension($manifest.FullName,$Source.extension)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Installateur correspondant au manifeste absent.' }
        $version=Get-AtelierManifestScalar $text 'PackageVersion'
        $hash=Get-AtelierManifestScalar $text 'InstallerSha256'
        $url=[uri](Get-AtelierManifestScalar $text 'InstallerUrl')
        $architecture=Get-AtelierManifestScalar $text 'Architecture'
        if ($version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,39}$' -or $hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Version ou SHA-256 de manifeste invalide.' }
        if ($architecture -ne $Source.architecture) { throw 'Architecture différente de la source configurée.' }
        if ($url.Scheme -ne 'https' -or $url.UserInfo -or $url.Host -notin $Source.hosts) { throw ('URL éditeur inattendue pour ' + $Source.key) }
        $file=Get-Item -LiteralPath $path
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installateur lie refuse.' }
        $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $hash.ToLowerInvariant()) { throw 'SHA-256 différent du manifeste WinGet : publication refusée.' }
        $signature=Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $Source.publisher) { throw 'Signature ou éditeur de l''installateur refuse.' }
        $candidates += [pscustomobject]@{path=$path;version=$version;sha256=$actual;url=$url.AbsoluteUri;publisher=$signature.SignerCertificate.Subject}
    }
    if ($candidates.Count -ne 1) { throw 'WinGet doit exporter exactement un manifeste et un installateur compatibles.' }
    return $candidates[0]
}

function Find-AtelierSoftwareBinding {
    param($State,$Source,[string]$BoundId)
    if ($BoundId) {
        $bound=@($State.applications | Where-Object { $_.id -eq $BoundId })
        if ($bound.Count -ne 1) { throw ('Liaison logicielle introuvable : ' + $Source.key) }
        return $bound[0]
    }
    $candidates=@($State.applications | Where-Object { $_.name -in $Source.aliases -and $_.install_mode -eq 'install' -and $_.manufacturer -eq 'all' })
    if ($candidates.Count -le 1) { return $candidates | Select-Object -First 1 }
    $used=@($State.bundles | ForEach-Object { $_.application_ids }) + @($State.profiles | ForEach-Object { $_.settings.application_ids })
    $referenced=@($candidates | Where-Object { $_.id -in $used })
    if ($referenced.Count -eq 1) { return $referenced[0] }
    throw ('Plusieurs entrées pour ' + $Source.key + ' : préciser -ApplicationBindings @{'+$Source.key+"='identifiant'} une fois.")
}

# Conserver la cause des erreurs des tâches et commandes natives, sans identifiants.
function Get-AtelierSoftwareErrorText {
    param($Record,[string[]]$Secrets=@())
    $text=[string]$Record
    if ($Record.Exception -and $Record.Exception.Message) { $text=[string]$Record.Exception.Message }
    if ($Record.ErrorDetails -and $Record.ErrorDetails.Message) {
        try {
            $detail=($Record.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop).detail
            if ($detail -is [string]) { $text=$detail }
        } catch { }
    }
    foreach ($secret in $Secrets) { if ($secret) { $text=$text.Replace($secret,'[masque]') } }
    $text=[regex]::Replace($text,'(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*','Bearer [masque]')
    $text=[regex]::Replace($text,'\x1B\[[0-?]*[ -/]*[@-~]','')
    return $text.Trim().Substring(0,[Math]::Min(1800,$text.Trim().Length))
}

function Invoke-AtelierWinGetDownload {
    param([string]$Executable,[string[]]$Arguments)
    # PowerShell 5.1 traite stderr comme un ErrorRecord, même pour les outils natifs.
    # Contrôler le code de retour WinGet ; une ligne informative sur stderr ne suffit pas à arrêter.
    $ErrorActionPreference='Continue'
    $tail=New-Object 'Collections.Generic.Queue[string]'
    $global:LASTEXITCODE=$null
    & $Executable @Arguments 2>&1 | ForEach-Object {
        $line=Get-AtelierSoftwareErrorText $_
        if ($line) {
            if ($tail.Count -ge 16) { $null=$tail.Dequeue() }
            $tail.Enqueue($line)
        }
    }
    $code=$global:LASTEXITCODE
    if ($null -eq $code -or $code -ne 0) {
        $description=if ($null -eq $code) { 'programme non démarré' } else { 'code ' + $code + ' / 0x' + ([int]$code).ToString('X8') }
        throw ('WinGet download en échec (' + $description + '). ' + ($tail.ToArray() -join ' | ') + ' Ancienne version conservée.')
    }
}
