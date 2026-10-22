#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$OutputDirectory = $PSScriptRoot)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$batteries = @(Get-CimInstance Win32_Battery)
if ($batteries.Count -eq 0) {
    'Aucune batterie détectée : normal sur une VM ou un ordinateur fixe.' | Set-Content (Join-Path $OutputDirectory 'Batterie-absente.txt') -Encoding UTF8
    Write-Host 'Aucune batterie détectée. Aucun rapport de capacité disponible.'
    return
}
$report = Join-Path $OutputDirectory 'Rapport-batterie.html'
& powercfg.exe /batteryreport /output $report /duration 14
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $report)) { throw 'La génération du rapport batterie a échoué.' }
Remove-Item (Join-Path $OutputDirectory 'Batterie-absente.txt') -ErrorAction SilentlyContinue
Write-Host "Rapport batterie : $report"
