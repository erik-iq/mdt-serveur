# Functions only: deterministic names from the BIOS serial number, no disk changes.
function Get-AtelierSerialSuffix {
    param([AllowEmptyString()][string]$SerialNumber)
    $serial=$SerialNumber.Trim().ToUpperInvariant()
    if (-not $serial -or $serial -match '^(TO BE FILLED|DEFAULT STRING|SYSTEM SERIAL|NONE$|UNKNOWN$|NOT SPECIFIED|0+$|F+$)') { throw 'Numero de serie absent ou generique. Saisir le nom du poste.' }
    $digits=$serial -replace '[^0-9]',''
    if ($digits.Length -lt 4) { throw 'Le numero de serie contient moins de quatre chiffres. Saisir le nom du poste.' }
    return $digits.Substring($digits.Length-4)
}
function Get-AtelierComputerName {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SerialNumber,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,10}$')][string]$Prefix='LE-T15-',
        [ValidateSet('characters','digits')][string]$SuffixMode='digits'
    )
    $serial=$SerialNumber.Trim().ToUpperInvariant()
    if (-not $serial -or $serial -match '^(TO BE FILLED|DEFAULT STRING|SYSTEM SERIAL|NONE$|UNKNOWN$|NOT SPECIFIED|0+$|F+$)') { throw 'Numero de serie BIOS absent ou generique : saisissez le nom manuellement.' }
    $value=if ($SuffixMode -eq 'digits') { $serial -replace '[^0-9]','' } else { $serial }
    if ($value.Length -lt 4) { throw 'Le numero de serie ne contient pas quatre donnees utilisables.' }
    $suffix=$value.Substring($value.Length-4)
    if ($suffix -notmatch '^[A-Z0-9]{4}$') { throw 'Les quatre derniers caracteres du numero de serie ne sont pas utilisables dans un nom Windows.' }
    $name=$Prefix.ToUpperInvariant()+$suffix
    if ($name -notmatch '^[A-Z][A-Z0-9-]{0,14}$') { throw 'Le nom genere depasse les limites Windows.' }
    return $name
}
