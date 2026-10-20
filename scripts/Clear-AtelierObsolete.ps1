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
# The retired HP extraction cache is independent of the signed HPIA/CMSL
# repository used by Windows. Only recognize the exact old WinPE cache.
$intelBuild=$false
$buildScript=Join-Path $InstallPath 'scripts\Build-WinPE.ps1'
if ((Test-Path (Join-Path $InstallPath 'scripts\WinPE-IntelDrivers.ps1') -PathType Leaf) -and (Test-Path $buildScript -PathType Leaf)) {
    $buildSource=Get-Content -LiteralPath $buildScript -Raw
    $intelBuild=$buildSource.Contains("'WinPE-IntelDrivers.ps1'") -and -not $buildSource.Contains("'WinPE-HPDrivers.ps1'")
}
foreach ($root in $SearchRoots | Where-Object { $_ } | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    if ($intelBuild) {
        $retired=Join-Path $root 'Drivers\WinPE-Official\HP-sp173204'
        if (Test-Path -LiteralPath $retired -PathType Container) {
            $recognized=$false
            try {
                $oldManifest=Join-Path $retired 'manifest.json'
                if (Test-Path $oldManifest -PathType Leaf) {
                    $old=Get-Content -LiteralPath $oldManifest -Raw | ConvertFrom-Json
                    $recognized=$old.softpaq -ceq 'sp173204' -and $old.source -ceq 'https://ftp.ext.hp.com/pub/softpaq/sp173001-173500/sp173204.exe'
                } elseif ((Test-Path (Join-Path $retired 'extraction-result.json') -PathType Leaf) -and (Test-Path (Join-Path $retired 'sp173204.exe') -PathType Leaf)) {
                    $old=Get-Content -LiteralPath (Join-Path $retired 'extraction-result.json') -Raw | ConvertFrom-Json
                    $recognized=$old.softpaq -ceq 'sp173204'
                }
                if ($recognized) {
                    # Leave a cache in use by an older construction alone.
                    $lockPath=Join-Path $retired 'build.lock'
                    if (Test-Path $lockPath -PathType Leaf) {
                        $lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                        $lock.Dispose()
                    }
                    $candidates.Add((Get-Item -LiteralPath $retired))
                }
            } catch { Write-Warning 'Ancien cache WinPE HP conserve : utilise ou non reconnu.' }
        }
    }
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
if ($intelBuild) {
    $obsolete=Join-Path $InstallPath 'scripts\WinPE-HPDrivers.ps1'
    if (Test-Path -LiteralPath $obsolete -PathType Leaf) {
        $item=Get-Item -LiteralPath $obsolete -Force
        $linked=$false;$parent=$item.Directory
        while ($parent) { if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked=$true;break };$parent=$parent.Parent }
        # Keep locally edited files. Accept the three published versions,
        # normalizing Windows line endings before comparing their fingerprints.
        $known=@('e580877959aea2535f524189e5300ce2bdf85a7737632462a5c646defe535e4f','a92cdb8a2cdc1953d173edce3349f28270db751dbcc72a009d164f94558ea29a','4f9e4798c2f9c770961bfbc3ff509bf4aec5614c6421c61801569ae2c4cf9fac')
        if (-not $linked -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $algorithm=[Security.Cryptography.SHA256]::Create()
            try { $hash=([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.File]::ReadAllText($obsolete) -replace "`r`n","`n"))))).Replace('-','').ToLowerInvariant() } finally { $algorithm.Dispose() }
            if ($hash -in $known -and $PSCmdlet.ShouldProcess($obsolete,'Supprimer l ancien extracteur WinPE HP remplace par Intel')) {
                Remove-Item -LiteralPath $obsolete -Force
                $results.Add(@{path=$obsolete;status='removed';timestamp=[DateTime]::UtcNow.ToString('o')})
            }
        }
    }
}
if (-not $WhatIfPreference) {
    $log=Join-Path $config.data_dir 'cleanup'
    New-Item -ItemType Directory -Path $log -Force | Out-Null
    ConvertTo-Json -InputObject @($results.ToArray()) -Depth 4 | Set-Content (Join-Path $log ('nettoyage-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Encoding UTF8
}
Write-Host ('Nettoyage termine : ' + $results.Count + ' element(s). Dernieres sauvegardes conservees : ' + $KeepBackups)
