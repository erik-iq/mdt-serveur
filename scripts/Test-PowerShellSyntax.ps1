param([string]$ScriptsPath = $PSScriptRoot)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference = 'Stop'
$count = 0
foreach ($file in Get-ChildItem $ScriptsPath -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) {
        $parseErrors | ForEach-Object { Write-Error "$($file.Name):$($_.Extent.StartLineNumber) $($_.Message)" -ErrorAction Continue }
        exit 1
    }
    $count++
}
Write-Host "Syntaxe PowerShell vérifiée : $count fichiers. Les opérations Windows n’ont pas été exécutées."
