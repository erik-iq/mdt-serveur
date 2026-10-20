#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,[string]$OutputRoot='D:\AtelierPXE',[string]$TrustedRootCertificate='C:\AtelierPXE\certs\AtelierPXE-lab.cer',[string]$DriversPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
if (-not (Test-Path $TrustedRootCertificate -PathType Leaf)) { throw 'Certificat public .cer absent ; fournir -TrustedRootCertificate.' }
if ($DriversPath -and -not (Test-Path $DriversPath -PathType Container)) { throw 'Dossier des pilotes WinPE absent.' }
if (-not $DriversPath) {
    foreach ($candidate in @((Join-Path $OutputRoot 'Drivers\WinPE-x64'),'C:\AtelierPXE\Drivers\WinPE-x64') | Select-Object -Unique) {
        if ((Test-Path $candidate -PathType Container) -and @(Get-ChildItem -LiteralPath $candidate -Filter '*.inf' -File -Recurse | Select-Object -First 1).Count) { $DriversPath=$candidate;break }
    }
}
$source=Split-Path $PSScriptRoot -Parent
$backup=Join-Path $env:ProgramData ('AtelierPXE\backups\atelier4-' + [guid]::NewGuid().ToString('N'))
& (Join-Path $PSScriptRoot 'Update-Console.ps1') -SourcePath $source -InstallPath $InstallPath -BackupPath $backup
& (Join-Path $InstallPath 'scripts\Enable-Atelier3.ps1') -InstallPath $InstallPath
& (Join-Path $InstallPath 'scripts\Enable-HPRepository.ps1') -InstallPath $InstallPath
& (Join-Path $InstallPath 'scripts\Set-AtelierDefaults.ps1') -InstallPath $InstallPath
& (Join-Path $InstallPath 'scripts\Sync-WindowsEditions.ps1') -InstallPath $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$output=Join-Path $OutputRoot ('WinPE-Atelier4-' + $stamp)
$imageName='Atelier PXE - ATELIER-4 - ' + $stamp
$parameters=@{ServerUrl=$config.base_url;OutputPath=$output;TrustedRootCertificate=$TrustedRootCertificate;WdsImageName=$imageName;ImportIntoWds=$true}
if ($DriversPath) { $parameters.DriversPath=$DriversPath }
& (Join-Path $InstallPath 'scripts\Build-WinPE.ps1') @parameters
# Only prune when a successfully built replacement has been imported and is visible.
& (Join-Path $InstallPath 'scripts\Remove-OldAtelierWinPE.ps1') -KeepImageName $imageName -KeepOutputPath $output -SearchRoots @($OutputRoot,'C:\AtelierPXE') -Confirm:$false
& (Join-Path $InstallPath 'scripts\Clear-AtelierObsolete.ps1') -InstallPath $InstallPath -SearchRoots @($OutputRoot,'C:\AtelierPXE',$env:TEMP) -ProtectedPaths @($backup,$source,$output) -Confirm:$false
Write-Host ('Nouvelle image : ' + (Join-Path $output 'media\sources\boot.wim')) -ForegroundColor Green
Write-Host 'Demarrer le poste sur ATELIER-4. Aucun accord prealable sur le site ; confirmer le disque dans WinPE.'
Write-Host 'Les reglages de reponse PXE de WDS ne sont pas modifies.'
