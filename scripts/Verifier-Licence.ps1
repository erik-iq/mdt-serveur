#requires -Version 5.1
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
$products = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Where-Object { $_.Name -like 'Windows*' -and -not $_.LicenseIsAddon })
$states = @{0='Sans licence';1='Activé';2='Délai initial';3='Délai de tolérance';4='Grâce non authentique';5='Notification';6='Grâce prolongée'}
$active = @($products | Where-Object { $_.LicenseStatus -eq 1 }).Count -gt 0
$status = if ($active) { 'ACTIVE' } elseif ($products.Count) { 'NON ACTIVE' } else { 'INDETERMINE' }
$displayStatus = if ($active) { 'Activée' } elseif ($products.Count) { 'Non activée' } else { 'Indéterminé' }
$report = [ordered]@{
    ordinateur=$env:COMPUTERNAME
    date=[DateTime]::UtcNow.ToString('o')
    etat=$status
    produits=@($products | ForEach-Object { @{nom=$_.Name;etat=$states[[int]$_.LicenseStatus];code=[int]$_.LicenseStatus;minutes_de_grace=$_.GracePeriodRemaining} })
}
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'Licence-Windows.json') -Encoding UTF8
@("Ordinateur : $env:COMPUTERNAME","Activation Windows : $displayStatus",'Ce diagnostic ne modifie pas la licence et ne contient aucune clé de produit.') | Set-Content (Join-Path $OutputDirectory 'Licence-Windows.txt') -Encoding UTF8
Write-Host "Activation Windows : $displayStatus"
