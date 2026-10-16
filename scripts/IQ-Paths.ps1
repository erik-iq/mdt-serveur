# Shared IQ layout. Explicit roots also support laboratory tests and migrations.
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
    # Reports made on an older deployment can still be regenerated.
    return (Join-Path $Root $Name)
}
