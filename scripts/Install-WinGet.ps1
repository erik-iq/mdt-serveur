#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if (Get-Command winget.exe -ErrorAction SilentlyContinue) { & winget.exe --version; return }
try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch { }
if (Get-Command winget.exe -ErrorAction SilentlyContinue) { & winget.exe --version; return }
Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -Repository PSGallery
Import-Module Microsoft.WinGet.Client
Repair-WinGetPackageManager -AllUsers
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    $package=Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($package -and (Test-Path (Join-Path $package.InstallLocation 'winget.exe'))) { & (Join-Path $package.InstallLocation 'winget.exe') --version;return }
    throw 'WinGet prepare ; rouvrir PowerShell sous le meme compte pour actualiser son enregistrement et son PATH.' }
& winget.exe --version
