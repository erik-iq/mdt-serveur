#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$DataPath='C:\ProgramData\AtelierPXE', [string]$OutputDirectory='C:\IQ_')
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& icacls.exe $OutputDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Permissions du dossier IQ_ impossibles.' }
foreach ($name in @('Test-Batterie.ps1','Verifier-Licence.ps1','Test-Materiel.ps1','Tests-Materiel.html','Verifier-Garantie.ps1','Export-Inventaire.ps1')) { Copy-Item -LiteralPath (Join-Path $DataPath $name) -Destination $OutputDirectory -Force }
$payload=Get-Content (Join-Path $DataPath 'personalization.json') -Raw | ConvertFrom-Json
if ($payload.wallpaper) {
    $source=Join-Path $DataPath ('Resources\' + $payload.wallpaper.filename)
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $payload.wallpaper.sha256) { throw 'Fond d ecran invalide avant copie dans IQ_.' }
    Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDirectory $payload.wallpaper.filename) -Force
}
foreach ($name in @('Test-Batterie','Verifier-Licence','Test-Materiel','Verifier-Garantie','Generer-Rapport','Export-Inventaire')) {
    # Double-clickable launchers request elevation only when needed by the scripts.
    $command = @"
@echo off
powershell.exe -NoProfile -Command "`$p=[char]34+'%~dp0$name.ps1'+[char]34; Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -File '+`$p)"
"@
    if ($name -in @('Test-Materiel','Verifier-Garantie','Generer-Rapport')) { $command=$command.Replace('-NoExit -File','-WindowStyle Hidden -File') }
    Set-Content -LiteralPath (Join-Path $OutputDirectory ($name + '.cmd')) -Value $command -Encoding ASCII
}
$reportLauncher=@'
param()
& (Join-Path $env:ProgramData 'AtelierPXE\New-DeploymentReport.ps1') -OutputDirectory $PSScriptRoot -RefreshInventory
'@
Set-Content -LiteralPath (Join-Path $OutputDirectory 'Generer-Rapport.ps1') -Value $reportLauncher -Encoding UTF8
$diagnostics=@()
foreach ($name in @('Test-Batterie.ps1','Verifier-Licence.ps1')) {
    try { & (Join-Path $OutputDirectory $name) -OutputDirectory $OutputDirectory; $diagnostics += @{script=$name;status='completed'} }
    catch { $diagnostics += @{script=$name;status='failed';message=$_.Exception.Message} }
}
$diagnostics | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDirectory 'Diagnostics.json') -Encoding UTF8
@('Dossier technique IQ_', '', 'Test-Batterie.cmd : genere Rapport-batterie.html (ou Batterie-absente.txt sur une VM).', 'Verifier-Licence.cmd : actualise Licence-Windows.txt et Licence-Windows.json.', 'Test-Materiel.cmd : test guide son, webcam et clavier dans le navigateur ; enregistre Tests-Materiel.json.', 'Generer-Rapport.cmd : actualise Rapport-Deploiement.pdf et .json, puis tente leur transmission a la console.', 'Verifier-Garantie.cmd : ouvre le site officiel du constructeur et permet de saisir les dates verifiees.', 'La garantie peut rester non verifiee ; aucune date n est inventee depuis le numero de serie.', 'Export-Inventaire.cmd : actualise Inventaire-Technique.xml et .csv avec les proprietes materielles, Windows, pilotes, logiciels et licences disponibles.', 'Les categories absentes ou inaccessibles sont signalees ; aucune cle produit, cle BitLocker ou TPM n est exportee.', 'Le fond d ecran selectionne est copie ici sous son nom d origine.', 'Les scripts de diagnostic ne changent ni la licence ni la configuration de la batterie.') | Set-Content (Join-Path $OutputDirectory 'Lisez-moi.txt') -Encoding UTF8
