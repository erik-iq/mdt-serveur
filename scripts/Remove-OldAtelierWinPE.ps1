#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$KeepImageName,
    [Parameter(Mandatory)][string]$KeepOutputPath,
    [string[]]$SearchRoots=@('D:\AtelierPXE','C:\AtelierPXE')
)
$ErrorActionPreference='Stop'
Import-Module WDS
$keep=[IO.Path]::GetFullPath($KeepOutputPath).TrimEnd('\')
$marker=Join-Path $keep 'atelier-winpe.json'
if (-not (Test-Path $marker) -or (Get-Content $marker -Raw | ConvertFrom-Json).release -ne 'ATELIER-4') { throw 'Nouvelle image ATELIER-4 validee absente ; aucune ancienne image supprimee.' }
$images=@(Get-WdsBootImage)
if (@($images | Where-Object { $_.ImageName -eq $KeepImageName }).Count -ne 1) { throw 'La nouvelle image doit etre importee dans WDS avant tout nettoyage.' }
$mounted=@(Get-WindowsImage -Mounted)
foreach ($image in $images) {
    if ($image.ImageName -eq $KeepImageName -or $image.ImageName -notmatch '^Atelier(?:\s*PXE)?(?:\s|[-_])') { continue }
    if ($PSCmdlet.ShouldProcess($image.ImageName,'Supprimer cette ancienne image de demarrage Atelier dans WDS')) {
        Write-Host ('Suppression image WDS Atelier : ' + $image.ImageName)
        & wdsutil.exe '/Remove-Image' ('/Image:' + $image.ImageName) '/ImageType:Boot' ('/Architecture:' + $image.Architecture) ('/Filename:' + $image.FileName)
        if ($LASTEXITCODE -ne 0) { throw ('Suppression WDS refusee : ' + $image.ImageName + '. Nettoyage disque interrompu.') }
    }
}
foreach ($root in $SearchRoots | Select-Object -Unique) {
    if (-not (Test-Path $root -PathType Container)) { continue }
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^WinPE(?:$|-)' })) {
        $full=[IO.Path]::GetFullPath($folder.FullName).TrimEnd('\')
        if ($full -eq $keep -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if (-not (Test-Path (Join-Path $full 'media\sources\boot.wim') -PathType Leaf)) { continue }
        if (@($mounted | Where-Object { $_.ImagePath -like ($full + '\*') -or $_.Path -like ($full + '\*') }).Count) {
            Write-Warning ('Image montee conservee : ' + $full);continue
        }
        if ($PSCmdlet.ShouldProcess($full,'Supprimer cet ancien dossier de construction WinPE Atelier')) { Write-Host ('Suppression dossier WinPE : ' + $full);Remove-Item -LiteralPath $full -Recurse -Force }
    }
}
Write-Host ('Image conservee : ' + $KeepImageName) -ForegroundColor Green
