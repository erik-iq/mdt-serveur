#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$batteries = @(Get-CimInstance Win32_Battery)
if ($batteries.Count -eq 0) {
    'Aucune batterie detectee : normal sur une VM ou un ordinateur fixe.' | Set-Content (Join-Path $OutputDirectory 'Batterie-absente.txt') -Encoding UTF8
    Write-Host 'Aucune batterie detectee. Aucun rapport de capacite disponible.'
    return
}
$report = Join-Path $OutputDirectory 'Rapport-batterie.html'
& powercfg.exe /batteryreport /output $report /duration 14
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $report)) { throw 'La generation du rapport batterie a echoue.' }
Remove-Item (Join-Path $OutputDirectory 'Batterie-absente.txt') -ErrorAction SilentlyContinue
Write-Host "Rapport batterie : $report"
