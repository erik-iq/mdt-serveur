#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RemoteInstallPath = 'D:\RemoteInstall',
    [switch]$DhcpOnThisServer
)
$ErrorActionPreference = 'Stop'
if ($RemoteInstallPath -notmatch '^[A-Za-z]:\\' -or $RemoteInstallPath -match '["\r\n]') { throw 'Un chemin local absolu est requis.' }
if (-not (Test-Path (Split-Path $RemoteInstallPath -Qualifier))) { throw 'Le volume de stockage est absent. Choisissez un volume NTFS dedie.' }
$drive = Get-Volume -DriveLetter $RemoteInstallPath.Substring(0,1)
if ($drive.FileSystem -ne 'NTFS') { throw 'Le stockage WDS necessite NTFS.' }
if (Test-Path $RemoteInstallPath) { throw 'Ce chemin existe deja. Ce script est reserve a une installation neuve et ne reconfigure pas un WDS existant.' }
if ((Get-WindowsFeature WDS).Installed) { throw 'WDS est deja installe. Utilisez sa console pour terminer la configuration ; ce script ne remplace pas une installation existante.' }
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Installer WDS autonome, initialiser le stockage et desactiver les reponses PXE')) {
    $result = Install-WindowsFeature WDS -IncludeManagementTools
    if (-not $result.Success -or $result.RestartNeeded -eq 'Yes') { throw 'Installation WDS incomplete ou redemarrage requis. Redemarrez puis terminez avec la console WDS.' }
    & wdsutil.exe /Initialize-Server "/RemInst:$RemoteInstallPath" /Standalone
    if ($LASTEXITCODE -ne 0) { throw 'Echec de l''initialisation WDS. Consultez les journaux WDS avant de poursuivre.' }
    & wdsutil.exe /Set-Server /AnswerClients:None
    if ($LASTEXITCODE -ne 0) { throw 'Impossible de desactiver les reponses PXE.' }
    if ($DhcpOnThisServer) {
        & wdsutil.exe /Set-Server /UseDhcpPorts:No /DhcpOption60:Yes
        if ($LASTEXITCODE -ne 0) { throw 'Echec des parametres de coexistence DHCP/WDS.' }
    }
    Write-Host 'WDS installe en mode autonome. Les reponses PXE sont desactivees.'
    Write-Host 'Importez WinPE, configurez DHCP/relais et selectionnez une politique de reponse dans la console WDS.'
}
