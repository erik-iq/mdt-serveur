#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallPath,
    [string]$OutputRoot='D:\AtelierPXE',
    [string]$TrustedRootCertificate='C:\AtelierPXE\certs\AtelierPXE-lab.cer',
    [ValidatePattern('^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$')][string]$WinPEKeyboardLayout='040c:0000040c',
    [string]$DriversPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation -InstallPath $InstallPath
Write-Host ('Console existante detectee : ' + $InstallPath)
$source=Split-Path $PSScriptRoot -Parent
$configPath=Join-Path $InstallPath 'data-runtime.json'
if (-not (Test-Path $configPath)) { throw 'Installation existante introuvable. Ce script met a jour DEPLOY-01, sans installer WDS ou Windows Server.' }
if (-not (Test-Path -LiteralPath $TrustedRootCertificate -PathType Leaf)) { throw 'Certificat public .cer absent : preciser -TrustedRootCertificate.' }
if ($DriversPath -and -not (Test-Path -LiteralPath $DriversPath -PathType Container)) { throw 'Dossier de pilotes WinPE absent.' }
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
& (Join-Path $PSScriptRoot 'Update-Console.ps1') -SourcePath $source -InstallPath $InstallPath
$config=Get-Content $configPath -Raw | ConvertFrom-Json
$health=Invoke-RestMethod -Uri ($config.base_url + '/health') -TimeoutSec 10
if ($health.release -ne 'ATELIER-2' -or $health.revision -ne '2.3') { throw 'La console ne confirme pas la revision ATELIER-2.3.' }
& (Join-Path $InstallPath 'scripts\Sync-WindowsEditions.ps1') -InstallPath $InstallPath
$parameters=@{
    ServerUrl=$config.base_url
    OutputPath=(Join-Path $OutputRoot ('WinPE-Atelier2-' + $stamp))
    TrustedRootCertificate=$TrustedRootCertificate
    WinPEKeyboardLayout=$WinPEKeyboardLayout
    WdsImageName=('Atelier PXE - ATELIER-2.1 - ' + $stamp)
    ImportIntoWds=$true
}
if ($DriversPath) { $parameters.DriversPath=$DriversPath }
& (Join-Path $InstallPath 'scripts\Build-WinPE.ps1') @parameters
Import-Module WDS
Get-WdsBootImage | Format-Table ImageName,Architecture,FileName
Write-Host 'Mise a jour terminee. Creer une nouvelle autorisation et choisir la nouvelle image ATELIER-2 pour le prochain test.' -ForegroundColor Green
