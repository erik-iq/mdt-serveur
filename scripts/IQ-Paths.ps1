
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Organisation IQ commune. Les racines explicites permettent aussi les tests et migrations.
function Get-AtelierIQDirectory {
    param([string]$Root='C:\IQ_',[ValidateSet('Diagnostics','Licence','Rapports','Inventaire','Garantie','Personnalisation')][string]$Category)
    $path=Join-Path $Root $Category
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function Get-AtelierIQFile {
    param([string]$Root='C:\IQ_',[string]$Category,[string]$Name)
    $path=Join-Path (Join-Path $Root $Category) $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    # Les rapports d’un ancien déploiement peuvent encore être régénérés.
    return (Join-Path $Root $Name)
}
