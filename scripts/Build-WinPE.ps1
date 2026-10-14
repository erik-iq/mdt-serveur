#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerUrl,
    [string]$OutputPath = 'C:\AtelierPXE\WinPE',
    [string]$DriversPath,
    [string]$TrustedRootCertificate,
    [string]$WdsImageName = 'Atelier PXE - WinPE x64',
    [switch]$ImportIntoWds,
    [switch]$AllowHttpForLab
)
$ErrorActionPreference = 'Stop'
$uri = [Uri]$ServerUrl
if ($uri.Scheme -ne 'https' -and -not ($AllowHttpForLab -and $uri.Scheme -eq 'http')) { throw 'Utilisez HTTPS, ou -AllowHttpForLab uniquement en laboratoire.' }
if ($uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'URL du serveur invalide.' }
if (Test-Path $OutputPath) { throw 'Le dossier de sortie existe déjà. Utilisez un nouveau chemin pour préserver vos fichiers.' }
$adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$peRoot = Join-Path $adk 'Windows Preinstallation Environment'
$envScript = Join-Path $adk 'Deployment Tools\DandISetEnv.bat'
$copype = Join-Path $peRoot 'copype.cmd'
$oc = Join-Path $peRoot 'amd64\WinPE_OCs'
foreach ($path in @($envScript, $copype, $oc)) { if (-not (Test-Path $path)) { throw "ADK ou module complémentaire WinPE absent : $path" } }
if ($OutputPath -match '["\r\n&|<>^%!]' -or $adk -match '["\r\n&|<>^%!]') { throw 'Chemin incompatible avec cmd.exe.' }
# Pass the complete command line directly to cmd.exe: Windows PowerShell 5.1's
# native argument handling otherwise removes quotes around ADK paths with spaces.
# Both batch files must run in the same process to retain the ADK environment.
$copyArguments = '/d /s /c "call "{0}" && call "{1}" amd64 "{2}""' -f $envScript, $copype, $OutputPath
$copyProcess = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList $copyArguments -NoNewWindow -Wait -PassThru
if ($copyProcess.ExitCode -ne 0) { throw "Échec de copype (code $($copyProcess.ExitCode))." }
$mount = Join-Path $OutputPath 'mount'
$wim = Join-Path $OutputPath 'media\sources\boot.wim'
$mounted = $false
try {
    Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount | Out-Null
    $mounted = $true
    foreach ($package in @('WinPE-WMI','WinPE-NetFX','WinPE-Scripting','WinPE-PowerShell','WinPE-StorageWMI','WinPE-DismCmdlets')) {
        Add-WindowsPackage -Path $mount -PackagePath (Join-Path $oc "$package.cab") | Out-Null
        $language = Join-Path $oc "en-us\${package}_en-us.cab"
        if (Test-Path $language) { Add-WindowsPackage -Path $mount -PackagePath $language | Out-Null }
    }
    if ($DriversPath) { Add-WindowsDriver -Path $mount -Driver $DriversPath -Recurse | Out-Null }
    $target = Join-Path $mount 'Atelier'
    New-Item -ItemType Directory -Path $target | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'Deploy.ps1'), (Join-Path $PSScriptRoot 'Launch.ps1') -Destination $target
    if ($TrustedRootCertificate) {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($TrustedRootCertificate)
        if ($certificate.HasPrivateKey -or $TrustedRootCertificate -notmatch '\.cer$') { throw 'Fournissez uniquement le certificat racine public .cer de votre autorité de confiance.' }
        Copy-Item $TrustedRootCertificate (Join-Path $target 'trusted-root.cer')
    }
    @{server_url=$ServerUrl.TrimEnd('/'); allow_http_for_lab=[bool]$AllowHttpForLab} | ConvertTo-Json | Set-Content (Join-Path $target 'config.json') -Encoding UTF8
    # Start an operator console; no image or disk is selected automatically.
    Set-Content (Join-Path $mount 'Windows\System32\startnet.cmd') -Encoding ASCII -Value "@echo off`r`nwpeinit`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Atelier\Launch.ps1`r`ncmd.exe"
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    $mounted = $false
} finally {
    if ($mounted) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
}
if ($ImportIntoWds) {
    Import-Module WDS
    Import-WdsBootImage -Path $wim -NewImageName $WdsImageName | Out-Null
}
Write-Host "Image WinPE : $wim"
Write-Host 'Testez une machine UEFI de laboratoire avant toute installation en production. Les images et séquences MDT existantes restent indépendantes.'
