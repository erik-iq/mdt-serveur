
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
function Get-AtelierPreparedWinGet {
    $candidates=@()
    $command=Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates+=@($command.Source) }
    foreach ($package in @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)) {
        if ($package.InstallLocation) { $candidates+=@(Join-Path $package.InstallLocation 'winget.exe') }
    }
    foreach ($path in @($candidates | Select-Object -Unique)) {
        try {
            $version=@(& $path --version 2>&1) -join ' '
            if ($LASTEXITCODE -eq 0 -and $version -match '^v?\d+\.\d+') { return $path }
        } catch { }
    }
    return $null
}
$winget=Get-AtelierPreparedWinGet
if ($winget) { & $winget --version;return }
try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch { }
$winget=Get-AtelierPreparedWinGet
if ($winget) { & $winget --version;return }
Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -AllowClobber -Confirm:$false -Repository PSGallery
Import-Module Microsoft.WinGet.Client
Repair-WinGetPackageManager -AllUsers
$winget=Get-AtelierPreparedWinGet
if (-not $winget) { throw 'WinGet non exécutable après sa préparation. Consulter software-logs\winget-preparation.log ; vérifier App Installer et la connexion Internet.' }
& $winget --version
