#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path = 'D:\AtelierPXE\data\artifacts',
    [string]$ShareName = 'AtelierImages',
    [Parameter(Mandatory)][string]$ReadOnlyAccount
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path -PathType Container)) { throw 'Le dossier des images est absent.' }
if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) { throw 'Le partage existe déjà. Examinez ses droits avant toute modification.' }
if ($PSCmdlet.ShouldProcess($Path, "Publier un partage SMB en lecture pour $ReadOnlyAccount")) {
    & icacls.exe $Path /grant "${ReadOnlyAccount}:(OI)(CI)RX"
    if ($LASTEXITCODE -ne 0) { throw 'Échec des permissions NTFS.' }
    New-SmbShare -Name $ShareName -Path $Path -ReadAccess $ReadOnlyAccount -EncryptData $true | Out-Null
    Write-Host "Partage créé : \\$env:COMPUTERNAME\$ShareName. Utilisez un compte dédié non administrateur."
}
