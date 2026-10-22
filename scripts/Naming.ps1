
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Fonctions seules : noms déterministes issus du numéro BIOS, sans modification du disque.
function Get-AtelierSerialSuffix {
    param([AllowEmptyString()][string]$SerialNumber)
    $serial=$SerialNumber.Trim().ToUpperInvariant()
    if (-not $serial -or $serial -match '^(TO BE FILLED|DEFAULT STRING|SYSTEM SERIAL|NONE$|UNKNOWN$|NOT SPECIFIED|0+$|F+$)') { throw 'Numéro de série absent ou générique. Saisir le nom du poste.' }
    $digits=$serial -replace '[^0-9]',''
    if ($digits.Length -lt 4) { throw 'Le numéro de série contient moins de quatre chiffres. Saisir le nom du poste.' }
    return $digits.Substring($digits.Length-4)
}
function Get-AtelierComputerName {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SerialNumber,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,10}$')][string]$Prefix='LE-T15-',
        [ValidateSet('characters','digits')][string]$SuffixMode='digits'
    )
    $serial=$SerialNumber.Trim().ToUpperInvariant()
    if (-not $serial -or $serial -match '^(TO BE FILLED|DEFAULT STRING|SYSTEM SERIAL|NONE$|UNKNOWN$|NOT SPECIFIED|0+$|F+$)') { throw 'Numéro de série BIOS absent ou générique : saisissez le nom manuellement.' }
    $value=if ($SuffixMode -eq 'digits') { $serial -replace '[^0-9]','' } else { $serial }
    if ($value.Length -lt 4) { throw 'Le numéro de série ne contient pas quatre données utilisables.' }
    $suffix=$value.Substring($value.Length-4)
    if ($suffix -notmatch '^[A-Z0-9]{4}$') { throw 'Les quatre derniers caractères du numéro de série ne sont pas utilisables dans un nom Windows.' }
    $name=$Prefix.ToUpperInvariant()+$suffix
    if ($name -notmatch '^[A-Z][A-Z0-9-]{0,14}$') { throw 'Le nom génère depasse les limites Windows.' }
    return $name
}
