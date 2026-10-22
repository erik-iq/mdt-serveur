#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$DataPath='C:\ProgramData\AtelierPXE', [string]$OutputDirectory='C:\IQ_')
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'IQ-Paths.ps1')
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& icacls.exe $OutputDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Permissions du dossier IQ_ impossibles.' }
$categories=@{Diagnostics=@('Test-Batterie','Test-Materiel');Licence=@('Verifier-Licence');Rapports=@('Generer-Rapport');Inventaire=@('Export-Inventaire');Garantie=@('Verifier-Garantie');Personnalisation=@()}
foreach ($category in $categories.Keys) {
    $directory=Get-AtelierIQDirectory $OutputDirectory $category
    foreach ($name in $categories[$category]) {
        if ($name -ne 'Generer-Rapport') { Copy-Item -LiteralPath (Join-Path $DataPath ($name + '.ps1')) -Destination $directory -Force }
        $command=@"
@echo off
powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -Command "`$p=[char]34+'%~dp0$name.ps1'+[char]34; Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '+`$p)"
"@
        Set-Content -LiteralPath (Join-Path $directory ($name + '.cmd')) -Value $command -Encoding ASCII
    }
}
Copy-Item -LiteralPath (Join-Path $DataPath 'Tests-Materiel.html') -Destination (Join-Path $OutputDirectory 'Diagnostics') -Force
# La garantie partage la palette Windows ; les tests matériels l’intègrent dans leur HTML.
foreach ($name in @('Theme.ps1','theme.json','brand-logo.png')) {
    Copy-Item -LiteralPath (Join-Path $DataPath $name) -Destination (Join-Path $OutputDirectory 'Garantie') -Force
    Copy-Item -LiteralPath (Join-Path $DataPath $name) -Destination (Join-Path $OutputDirectory 'Diagnostics') -Force
}
$reportLauncher=@'
param()
& (Join-Path $env:ProgramData 'AtelierPXE\New-DeploymentReport.ps1') -OutputDirectory (Split-Path $PSScriptRoot -Parent) -RefreshInventory
'@
Set-Content -LiteralPath (Join-Path $OutputDirectory 'Rapports\Generer-Rapport.ps1') -Value $reportLauncher -Encoding UTF8
$payload=Get-Content (Join-Path $DataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
if ('hpia' -in @($payload.settings.winget_packages)) {
    . (Join-Path $DataPath 'Client-Software.ps1')
    $hpTool=Get-AtelierInstalledClientSoftware 'hpia'
    if ($hpTool) { New-AtelierHpiaLauncher -ToolsPath $OutputDirectory }
}
if ($payload.settings.central_inventory) {
    $centralLauncher=@'
param()
$atelierData=Join-Path $env:ProgramData 'AtelierPXE'
$atelierCache=Join-Path $atelierData 'Inventory'
& (Join-Path $atelierData 'Export-Inventaire.ps1') -OutputDirectory $atelierCache | Out-Null
. (Join-Path $atelierData 'Inventory-Transfer.ps1')
if (-not (Send-AtelierInventory -DataPath $atelierData -InventoryDirectory $atelierCache)) { Write-Warning 'Transmission en attente ; cache privé conserve.' }
'@
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'Inventaire\Export-Inventaire.ps1') -Value $centralLauncher -Encoding UTF8
} else {
    $localLauncher=@'
param()
& (Join-Path $env:ProgramData 'AtelierPXE\Export-Inventaire.ps1') -OutputDirectory $PSScriptRoot
'@
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'Inventaire\Export-Inventaire.ps1') -Value $localLauncher -Encoding UTF8
}
if ($payload.wallpaper) {
    $source=Join-Path $DataPath ('Resources\' + $payload.wallpaper.filename)
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $payload.wallpaper.sha256) { throw 'Fond d''écran invalide avant copie dans IQ_.' }
    Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDirectory ('Personnalisation\' + $payload.wallpaper.filename)) -Force
}
# Déplacer uniquement les résultats connus de l’ancienne disposition. Préserver les autres fichiers.
foreach ($entry in @(
    @{category='Licence';pattern='Licence-Windows.*'},
    @{category='Diagnostics';pattern='Rapport-batterie.html'},
    @{category='Diagnostics';pattern='Batterie-absente.txt'},
    @{category='Diagnostics';pattern='Tests-Materiel.json'},
    @{category='Diagnostics';pattern='Diagnostics.json'},
    @{category='Rapports';pattern='Rapport-Deploiement.*'},
    @{category='Rapports';pattern='Transmission-Rapport.json'},
    @{category='Inventaire';pattern='Inventaire-Technique.*'},
    @{category='Garantie';pattern='Garantie.*'}
)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $OutputDirectory -Filter $entry.pattern -File)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $target=Join-Path (Join-Path $OutputDirectory $entry.category) $file.Name
        if (-not (Test-Path $target)) { Move-Item -LiteralPath $file.FullName -Destination $target }
    }
}
foreach ($category in $categories.Keys) {
    foreach ($name in $categories[$category]) {
        foreach ($extension in @('.ps1','.cmd')) {
            $legacy=Join-Path $OutputDirectory ($name + $extension)
            if (Test-Path $legacy -PathType Leaf) { Remove-Item -LiteralPath $legacy -Force }
        }
    }
}
$legacyHtml=Join-Path $OutputDirectory 'Tests-Materiel.html'
if (Test-Path $legacyHtml -PathType Leaf) { Remove-Item -LiteralPath $legacyHtml -Force }
$diagnostics=@()
foreach ($entry in @(@{name='Test-Batterie';category='Diagnostics'},@{name='Verifier-Licence';category='Licence'})) {
    $directory=Join-Path $OutputDirectory $entry.category
    try { & (Join-Path $directory ($entry.name + '.ps1')) -OutputDirectory $directory; $diagnostics+=@{script=$entry.name;status='completed'} }
    catch { $diagnostics+=@{script=$entry.name;status='failed';message=$_.Exception.Message} }
}
$diagnostics | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDirectory 'Diagnostics\Diagnostics.json') -Encoding UTF8
@(
    'IQ Atelier - dossier technique', '',
    'Diagnostics : tests son, webcam, clavier et batterie.',
    'Licence : état de l''activation Windows.',
    'Rapports : PDF de déploiement, JSON et outil Generer-Rapport.cmd.',
    'Inventaire : outil Export-Inventaire.cmd pour actualiser les XML/CSV.',
    'Garantie : vérification des dates sur le site officiel du constructeur.',
    'Personnalisation : fond d''écran sélectionne.', '',
    'Constructeur : HP-ImageAssistant.cmd si HPIA a été coché et vérifié.',
    'Les dates de garantie restent non vérifiées tant que l''opérateur ne les a pas confirmées.',
    'Aucune clé produit, clé BitLocker ou TPM n''est exportée.',
    $(if($payload.settings.central_inventory){'XML/CSV sur le serveur .250 : ouvrir Dossier inventaire dans Atelier. Cache privé dans ProgramData\AtelierPXE\Inventory.'}else{'XML/CSV dans Inventaire.'})
) | Set-Content (Join-Path $OutputDirectory 'Lisez-moi.txt') -Encoding UTF8
