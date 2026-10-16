#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$products = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Where-Object { $_.Name -like 'Windows*' -and -not $_.LicenseIsAddon })
$states = @{0='Sans licence';1='Active';2='Delai initial';3='Delai de tolerance';4='Grace non authentique';5='Notification';6='Grace prolongee'}
$active = @($products | Where-Object { $_.LicenseStatus -eq 1 }).Count -gt 0
$status = if ($active) { 'ACTIVE' } elseif ($products.Count) { 'NON ACTIVE' } else { 'INDETERMINE' }
$report = [ordered]@{
    ordinateur=$env:COMPUTERNAME
    date=[DateTime]::UtcNow.ToString('o')
    etat=$status
    produits=@($products | ForEach-Object { @{nom=$_.Name;etat=$states[[int]$_.LicenseStatus];code=[int]$_.LicenseStatus;minutes_de_grace=$_.GracePeriodRemaining} })
}
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'Licence-Windows.json') -Encoding UTF8
@("Ordinateur : $env:COMPUTERNAME","Activation Windows : $status",'Ce diagnostic ne modifie pas la licence et ne contient aucune cle de produit.') | Set-Content (Join-Path $OutputDirectory 'Licence-Windows.txt') -Encoding UTF8
Write-Host "Activation Windows : $status"
