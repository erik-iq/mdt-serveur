#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,[string]$OutputRoot='D:\AtelierPXE',[string]$TrustedRootCertificate='C:\AtelierPXE\certs\AtelierPXE-lab.cer',[string]$DriversPath,[string]$BrandLogoPath)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
# Le PNG original facultatif remplace le logo adapté des deux interfaces avant copie.
if ($BrandLogoPath) {
    if (-not (Test-Path $BrandLogoPath -PathType Leaf) -or [IO.Path]::GetExtension($BrandLogoPath) -ine '.png') { throw 'Fournir un logo PNG.' }
    Add-Type -AssemblyName System.Drawing
    $image=[Drawing.Image]::FromFile((Resolve-Path $BrandLogoPath).ProviderPath)
    try { if ($image.Width -gt 8192 -or $image.Height -gt 8192) { throw 'Logo trop grand.' } } finally { $image.Dispose() }
    Copy-Item -LiteralPath $BrandLogoPath -Destination (Join-Path $PSScriptRoot 'brand-logo.png') -Force
    Copy-Item -LiteralPath $BrandLogoPath -Destination (Join-Path (Split-Path $PSScriptRoot -Parent) 'app\static\brand-logo.png') -Force
}
$parameters=@{OutputRoot=$OutputRoot;TrustedRootCertificate=$TrustedRootCertificate}
if ($InstallPath) { $parameters.InstallPath=$InstallPath }
if ($DriversPath) { $parameters.DriversPath=$DriversPath }
& (Join-Path $PSScriptRoot 'Upgrade-Atelier3.ps1') @parameters
