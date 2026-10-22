#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path = 'D:\AtelierPXE\data\artifacts',
    [string]$ShareName = 'AtelierImages',
    [Parameter(Mandatory)][string]$ReadOnlyAccount
)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path -PathType Container)) { throw 'Le dossier des images est absent.' }
if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) { throw 'Le partage existe déjà. Examinez ses droits avant toute modification.' }
if ($PSCmdlet.ShouldProcess($Path, "Publier un partage SMB en lecture pour $ReadOnlyAccount")) {
    & icacls.exe $Path /grant "${ReadOnlyAccount}:(OI)(CI)RX"
    if ($LASTEXITCODE -ne 0) { throw 'Échec des permissions NTFS.' }
    New-SmbShare -Name $ShareName -Path $Path -ReadAccess $ReadOnlyAccount -EncryptData $true | Out-Null
    Write-Host "Partage crée : \\$env:COMPUTERNAME\$ShareName. Utilisez un compte dedie non administrateur."
}
