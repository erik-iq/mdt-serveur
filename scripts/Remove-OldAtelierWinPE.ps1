#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$KeepImageName,
    [Parameter(Mandatory)][string]$KeepOutputPath,
    [string[]]$SearchRoots=@('D:\AtelierPXE','C:\AtelierPXE')
)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
Import-Module WDS
$keep=[IO.Path]::GetFullPath($KeepOutputPath).TrimEnd('\')
$marker=Join-Path $keep 'atelier-winpe.json'
if (-not (Test-Path $marker) -or (Get-Content $marker -Encoding UTF8 -Raw | ConvertFrom-Json).release -ne 'ATELIER-4') { throw 'Nouvelle image ATELIER-4 validée absente ; aucune ancienne image supprimée.' }
$newWim=Join-Path $keep 'media\sources\boot.wim'
if (-not (Test-Path $newWim -PathType Leaf) -or (Get-Item -LiteralPath $newWim).Length -eq 0) { throw 'Nouveau boot.wim absent ou vide ; nettoyage refusé.' }
$images=@(Get-WdsBootImage)
if (@($images | Where-Object { $_.ImageName -eq $KeepImageName }).Count -ne 1) { throw 'La nouvelle image doit être importée dans WDS avant tout nettoyage.' }
$mounted=@(Get-WindowsImage -Mounted)
$wdsCleanupFailed=$false
function Get-AtelierWdsArchitecture([object]$Value) {
    # WDS peut renvoyer le code numérique du processeur plutôt que son nom.
    switch (([string]$Value).ToLowerInvariant()) {
        '0' { return 'x86' }
        '9' { return 'x64' }
        '6' { return 'ia64' }
        '12' { return 'arm64' }
        'amd64' { return 'x64' }
        'x86' { return 'x86' }
        'x64' { return 'x64' }
        'ia64' { return 'ia64' }
        'arm64' { return 'arm64' }
        default { throw ('Architecture WDS inconnue : ' + $Value) }
    }
}
foreach ($image in $images) {
    if ($image.ImageName -eq $KeepImageName -or $image.ImageName -match '(?i)(MDT|LiteTouch)' -or $image.ImageName -notmatch '^Atelier(?:\s*PXE)?(?:\s|[-_])') { continue }
    if ($PSCmdlet.ShouldProcess($image.ImageName,'Supprimer cette ancienne image de démarrage Atelier dans WDS')) {
        Write-Host ('Suppression image WDS Atelier : ' + $image.ImageName)
        try {
            $architecture=Get-AtelierWdsArchitecture $image.Architecture
            $arguments=@('/Remove-Image',('/Image:' + $image.ImageName),'/ImageType:Boot',('/Architecture:' + $architecture))
            if ($image.FileName) { $arguments+=('/Filename:' + [IO.Path]::GetFileName($image.FileName)) }
            $nativeOutput=@(& wdsutil.exe @arguments 2>&1)
            $nativeExitCode=$LASTEXITCODE
            $nativeOutput | ForEach-Object { Write-Host ([string]$_) }
            if ($nativeExitCode -ne 0) {
                throw ('Code WDS ' + $nativeExitCode + '. ' + ($nativeOutput -join [Environment]::NewLine))
            }
            if (@(Get-WdsBootImage | Where-Object {
                $_.ImageName -eq $image.ImageName -and
                (Get-AtelierWdsArchitecture $_.Architecture) -eq $architecture
            }).Count) { throw 'L''ancienne image reste enregistrée dans WDS après la commande.' }
        } catch {
            $wdsCleanupFailed=$true
            Write-Warning ('Ancienne image WDS conservée : ' + $image.ImageName + '. ' + $_.Exception.Message)
        }
    }
}
if ($wdsCleanupFailed) {
    # Aucun dossier de construction supprimé si WDS conserve une ancienne image.
    Write-Warning 'Nettoyage des anciens dossiers différé. Le nouveau WinPE reste disponible ; aucune reconstruction nécessaire.'
    Write-Host ('Image conservée : ' + $KeepImageName) -ForegroundColor Green
    return
}
foreach ($root in $SearchRoots | Select-Object -Unique) {
    if (-not (Test-Path $root -PathType Container)) { continue }
    # Une racine alias peut désigner KeepOutputPath sous une autre lettre de lecteur.
    $rootInfo=Get-Item -LiteralPath $root -Force
    $linked=$false
    while ($rootInfo) {
        if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked=$true;break }
        $rootInfo=$rootInfo.Parent
    }
    if ($linked) { continue }
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^WinPE(?:$|-)' })) {
        $full=[IO.Path]::GetFullPath($folder.FullName).TrimEnd('\')
        if ($full -eq $keep -or $folder.Name -match '(?i)(MDT|LiteTouch)' -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if (-not (Test-Path (Join-Path $full 'media\sources\boot.wim') -PathType Leaf)) { continue }
        if (@(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1).Count) { continue }
        if (@($mounted | Where-Object { $_.ImagePath -like ($full + '\*') -or $_.Path -like ($full + '\*') }).Count) {
            Write-Warning ('Image montée conservée : ' + $full);continue
        }
        if ($PSCmdlet.ShouldProcess($full,'Supprimer cet ancien dossier de construction WinPE Atelier')) { Write-Host ('Suppression dossier WinPE : ' + $full);Remove-Item -LiteralPath $full -Recurse -Force }
    }
}
Write-Host ('Image conservée : ' + $KeepImageName) -ForegroundColor Green
