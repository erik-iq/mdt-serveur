#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InstallPath,
    [string[]]$SearchRoots=@('C:\AtelierPXE','D:\AtelierPXE',$env:TEMP),
    [string]$BackupDirectory=(Join-Path $env:ProgramData 'AtelierPXE\backups'),
    [string[]]$ProtectedPaths=@(),
    [ValidateRange(1,100)][int]$KeepBackups=3,
    [ValidateRange(0,8760)][int]$MinimumAgeHours=1
)
$ErrorActionPreference='Stop'
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$separator=[IO.Path]::DirectorySeparatorChar
function Full-Path([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd($separator) }
$protected=@($InstallPath,$config.data_dir,$PSScriptRoot,(Split-Path $PSScriptRoot -Parent)) + $ProtectedPaths
$protected=@($protected | Where-Object { $_ } | ForEach-Object { Full-Path $_ })
$cutoff=[DateTime]::UtcNow.AddHours(-$MinimumAgeHours)
$candidates=New-Object 'Collections.Generic.List[object]'
foreach ($root in $SearchRoots | Where-Object { $_ } | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    foreach ($item in @(Get-ChildItem -LiteralPath $root)) {
        if ($item.Name -match '^(?:Maj-Atelier[234]-[a-f0-9]{32}|Atelier-[234]-[a-f0-9]{32}|Atelier-Logiciels-[a-f0-9]{32})$' -and $item.PSIsContainer) {
            # A source archive staging folder must actually contain our project.
            foreach ($source in @($item.FullName,(Join-Path $item.FullName 'source'))) {
                if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
                $projects=@(Get-ChildItem -LiteralPath $source -Directory | Where-Object { $_.Name -match '^mdt-serveur-[a-f0-9]{40}$' })
                if (@($projects | Where-Object { Test-Path (Join-Path $_.FullName 'scripts\Update-Console.ps1') -PathType Leaf }).Count -eq 1) { $candidates.Add($item) }
            }
        }
    }
}
foreach ($BackupDirectory in (@($BackupDirectory) + @($SearchRoots | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'backups' }) | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) { continue }
    $backups=@(Get-ChildItem -LiteralPath $BackupDirectory -Directory | Where-Object {
        $_.Name -match '^(?:atelier[234]-[a-f0-9]{32}|console-\d{8}-\d{6})$' -and
        ((Test-Path (Join-Path $_.FullName 'console\data-runtime.json') -PathType Leaf) -or (Test-Path (Join-Path $_.FullName 'data-runtime.json') -PathType Leaf)) -and
        (Test-Path (Join-Path $_.FullName 'deployment.sqlite3') -PathType Leaf)
    } | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($backup in @($backups | Select-Object -Skip $KeepBackups)) { $candidates.Add($backup) }
}
$results=New-Object 'Collections.Generic.List[object]'
foreach ($item in $candidates | Sort-Object FullName -Unique) {
    $full=Full-Path $item.FullName
    $blocked=@($protected | Where-Object {
        $full.Equals($_,[StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($_ + $separator,[StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith($full + $separator,[StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    if ($blocked -or $item.LastWriteTimeUtc -gt $cutoff) { continue }
    # Refuse a linked directory or any linked descendant, including junctions.
    $current=$item
    while ($current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { $blocked=$true;break }
        $current=$current.Parent
    }
    if ($blocked -or @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1).Count) { continue }
    if ($PSCmdlet.ShouldProcess($full,'Supprimer un ancien dossier Atelier identifie')) {
        Remove-Item -LiteralPath $full -Recurse -Force
        $results.Add(@{path=$full;status='removed';timestamp=[DateTime]::UtcNow.ToString('o')})
        Write-Host ('Ancien dossier supprime : ' + $full)
    }
}
if (-not $WhatIfPreference) {
    $log=Join-Path $config.data_dir 'cleanup'
    New-Item -ItemType Directory -Path $log -Force | Out-Null
    ConvertTo-Json -InputObject @($results.ToArray()) -Depth 4 | Set-Content (Join-Path $log ('nettoyage-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Encoding UTF8
}
Write-Host ('Nettoyage termine : ' + $results.Count + ' dossier(s). Dernieres sauvegardes conservees : ' + $KeepBackups)
