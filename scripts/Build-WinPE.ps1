#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerUrl,
    [string]$OutputPath = 'C:\AtelierPXE\WinPE',
    [string]$DriversPath,
    [string]$DriverCacheRoot = 'C:\AtelierPXE\Drivers\WinPE-Official',
    [string]$TrustedRootCertificate,
    [string]$WdsImageName = 'Atelier PXE - Assistant Windows x64',
    [switch]$ImportIntoWds,
    [switch]$AllowHttpForLab,
    [ValidateSet('100c:0000100c')]
    [string]$WinPEKeyboardLayout = '100c:0000100c'
)
$ErrorActionPreference = 'Stop'
$uri = [Uri]$ServerUrl
if ($uri.Scheme -ne 'https' -and -not ($AllowHttpForLab -and $uri.Scheme -eq 'http')) { throw 'Utilisez HTTPS, ou -AllowHttpForLab uniquement en laboratoire.' }
if ($uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'URL du serveur invalide.' }
if (Test-Path $OutputPath) { throw 'Le dossier de sortie existe deja. Utilisez un nouveau chemin pour preserver vos fichiers.' }
$adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$peRoot = Join-Path $adk 'Windows Preinstallation Environment'
$envScript = Join-Path $adk 'Deployment Tools\DandISetEnv.bat'
$copype = Join-Path $peRoot 'copype.cmd'
$oc = Join-Path $peRoot 'amd64\WinPE_OCs'
foreach ($path in @($envScript, $copype, $oc)) { if (-not (Test-Path $path)) { throw "ADK ou module complementaire WinPE absent : $path" } }
foreach ($script in @('Deploy.ps1','Launch.ps1','Wizard.ps1','Unattend.ps1','FirstLogon.ps1','WinPE-Session.ps1','WinPE-NetworkRecovery.ps1','Partitions.ps1','Naming.ps1','Prepare-Windows.ps1','Maintenance.ps1','Progress.ps1','Updates.ps1','Prepare-IQTools.ps1','Test-Batterie.ps1','Verifier-Licence.ps1','Reporting.ps1','New-DeploymentReport.ps1','Launch-Tools.ps1','HP-ImageAssistant.ps1','HP-Repository.ps1','HP-ClientRepository.ps1','HP-Reports.ps1','Test-Materiel.ps1','Tests-Materiel.html','Verifier-Garantie.ps1','Export-Inventaire.ps1','Client-Software.ps1','Install-WinGet.ps1','software-sources.json','Inventory-Transfer.ps1','Finalization.ps1','Timings.ps1','Start-Preparation.ps1','IQ-Paths.ps1','Theme.ps1','theme.json','brand-logo.png','atelier.cmd')) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $script))) { throw "Mettez a jour tous les fichiers du projet avant la construction : $script absent." }
}
if ($OutputPath -match '["\r\n&|<>^%!]' -or $adk -match '["\r\n&|<>^%!]') { throw 'Chemin incompatible avec cmd.exe.' }
if ($DriversPath -and -not (Test-Path $DriversPath -PathType Container)) { throw 'Dossier des pilotes WinPE supplementaires absent.' }
. (Join-Path $PSScriptRoot 'WinPE-IntelDrivers.ps1')
$baseImage=Get-WindowsImage -ImagePath (Join-Path $peRoot 'amd64\en-us\winpe.wim') -Index 1 -ErrorAction Stop
$networkDrivers=Get-AtelierIntelI219Driver -CacheRoot $DriverCacheRoot -WinPEVersion ([version]$baseImage.Version)
if (@($networkDrivers.network_infs).Count -ne 1) { throw 'La selection Intel doit contenir exactement un INF.' }
# Pass the complete command line directly to cmd.exe: Windows PowerShell 5.1's
# native argument handling otherwise removes quotes around ADK paths with spaces.
# Both batch files must run in the same process to retain the ADK environment.
$copyArguments = '/d /s /c "call "{0}" && call "{1}" amd64 "{2}""' -f $envScript, $copype, $OutputPath
$copyProcess = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList $copyArguments -NoNewWindow -Wait -PassThru
if ($copyProcess.ExitCode -ne 0) { throw "Echec de copype (code $($copyProcess.ExitCode))." }
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
    # One selected I219 INF; the ADK's inbox driver store is retained.
    foreach ($inf in $networkDrivers.network_infs) {
        Write-Host ('Integration reseau WinPE : '+[IO.Path]::GetFileName($inf))
        Add-WindowsDriver -Path $mount -Driver $inf -ErrorAction Stop | Out-Null
    }
    $infHash=(Get-FileHash -LiteralPath $networkDrivers.network_infs[0] -Algorithm SHA256).Hash.ToLowerInvariant()
    $storedInf=Get-ChildItem -LiteralPath (Join-Path $mount 'Windows\System32\DriverStore\FileRepository') -Filter ([IO.Path]::GetFileName($networkDrivers.network_infs[0])) -Recurse -File | Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $infHash } | Select-Object -First 1
    if (-not $storedInf) { throw 'Le pilote I219 est introuvable dans le DriverStore apres integration. Image non publiee.' }
    $recovery=@{inf=$storedInf.FullName.Substring([IO.Path]::GetFullPath($mount).TrimEnd([char[]]'\/').Length+1);sha256=$infHash}
    if ($DriversPath) { Add-WindowsDriver -Path $mount -Driver $DriversPath -Recurse -ErrorAction Stop | Out-Null }
    $keyboardArguments='/Image:"{0}" /Set-InputLocale:100c:0000100c' -f $mount
    $keyboardProcess=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') -ArgumentList $keyboardArguments -NoNewWindow -Wait -PassThru
    if ($keyboardProcess.ExitCode -ne 0) { throw ('Impossible de preparer le clavier francais suisse dans WinPE (code '+$keyboardProcess.ExitCode+').') }
    $target = Join-Path $mount 'Atelier'
    New-Item -ItemType Directory -Path $target | Out-Null
    foreach ($script in @('Deploy.ps1','Launch.ps1','Wizard.ps1','Unattend.ps1','FirstLogon.ps1','WinPE-Session.ps1','WinPE-NetworkRecovery.ps1','Partitions.ps1','Naming.ps1','Prepare-Windows.ps1','Maintenance.ps1','Progress.ps1','Updates.ps1','Prepare-IQTools.ps1','Test-Batterie.ps1','Verifier-Licence.ps1','Reporting.ps1','New-DeploymentReport.ps1','Launch-Tools.ps1','HP-ImageAssistant.ps1','HP-Repository.ps1','HP-ClientRepository.ps1','HP-Reports.ps1','Test-Materiel.ps1','Tests-Materiel.html','Verifier-Garantie.ps1','Export-Inventaire.ps1','Client-Software.ps1','Install-WinGet.ps1','software-sources.json','Inventory-Transfer.ps1','Finalization.ps1','Timings.ps1','Start-Preparation.ps1','IQ-Paths.ps1','Theme.ps1','theme.json','brand-logo.png')) {
        Copy-Item (Join-Path $PSScriptRoot $script) -Destination $target
    }
    # GitHub source archives can use LF. Always write a Windows batch file.
    $recoveryMenu = (Get-Content (Join-Path $PSScriptRoot 'atelier.cmd') -Encoding UTF8 -Raw) -replace '\r?\n', "`r`n"
    Set-Content (Join-Path $mount 'Windows\System32\atelier.cmd') -Value $recoveryMenu -Encoding ASCII
    if ($TrustedRootCertificate) {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($TrustedRootCertificate)
        if ($certificate.HasPrivateKey -or $TrustedRootCertificate -notmatch '\.cer$') { throw 'Fournissez uniquement le certificat racine public .cer de votre autorite de confiance.' }
        Copy-Item $TrustedRootCertificate (Join-Path $target 'trusted-root.cer')
    }
    $internalMode = $false
    $runtimeConfig = $null
    $runtimePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'data-runtime.json'
    if (Test-Path $runtimePath) { $runtimeConfig = Get-Content $runtimePath -Encoding UTF8 -Raw | ConvertFrom-Json; $internalMode = [bool]$runtimeConfig.internal_mode }
    @{auto_enroll=[bool]$runtimeConfig.auto_enroll;internal_mode=$internalMode; server_url=$ServerUrl.TrimEnd('/'); allow_http_for_lab=[bool]$AllowHttpForLab; image_share=('\\' + $uri.Host + '\AtelierImages'); share_account=($env:COMPUTERNAME + '\DeployRead'); winpe_keyboard_layout=$WinPEKeyboardLayout; boot_release='ATELIER-4';i219_recovery=$recovery; built_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $target 'config.json') -Encoding UTF8
    # Each relaunch uses a new STA process; no credentials on its command line.
    Set-Content (Join-Path $mount 'Windows\System32\startnet.cmd') -Encoding ASCII -Value "@echo off`r`nwpeinit`r`ncall %SystemRoot%\System32\atelier.cmd`r`ncmd.exe`r`n"
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    $mounted = $false
    @{release='ATELIER-4';ui_revision='IQ-5.3.1';network_drivers=$networkDrivers;server_url=$ServerUrl;wim='media\sources\boot.wim';built_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputPath 'atelier-winpe.json') -Encoding UTF8
} finally {
    if ($mounted) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
}
if ($ImportIntoWds) {
    Import-Module WDS
    Import-WdsBootImage -Path $wim -NewImageName $WdsImageName | Out-Null
}
Write-Host "Image WinPE : $wim"
Write-Host 'Testez une machine UEFI de laboratoire avant toute installation en production. Les images et sequences MDT existantes restent independantes.'
