# Intel download record 727998, Wired_driver_31.2.2_x64.zip (July 2026).
# Only the legacy NDIS I219 package is selected, never the complete driver set.
function Assert-AtelierIntelCachePath {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien interdit dans le cache Intel WinPE.' }
        $item=$item.Parent
    }
}
function Get-AtelierIntelTree {
    param([string]$Path)
    Assert-AtelierIntelCachePath $Path
    $root=[IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    $items=@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Lien interdit dans les pilotes Intel.' }
    foreach ($file in $items | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName) {
        [pscustomobject]@{name=$file.FullName.Substring($root.Length);sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
function Expand-AtelierIntelArchive {
    param([string]$Archive,[string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root=[IO.Path]::GetFullPath($Destination).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 16000 -or ($zip.Entries | Measure-Object Length -Sum).Sum -gt 1GB) { throw 'Archive Intel hors limites.' }
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        # Validate every path before writing any entry, including on .NET Framework.
        $targets=New-Object 'Collections.Generic.List[object]'
        foreach ($entry in $zip.Entries) {
            $name=$entry.FullName.Replace('\','/')
            if (-not $name -or $name.StartsWith('/') -or $name -match '[<>:"|?*\x00-\x1f]' -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960) { throw 'Chemin refuse dans le ZIP Intel.' }
            $segments=$name.TrimEnd('/').Split('/')
            if (@($segments | Where-Object { -not $_ -or $_ -in @('.','..') -or $_ -match '[. ]$' -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' }).Count -or -not $seen.Add($name.TrimEnd('/'))) { throw 'Chemin ambigu dans le ZIP Intel.' }
            $target=[IO.Path]::GetFullPath((Join-Path $Destination ($name.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            if (-not $target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin Intel hors du cache.' }
            $targets.Add([pscustomobject]@{entry=$entry;path=$target;directory=$name.EndsWith('/')})
        }
        foreach ($target in $targets) {
            if ($target.directory) { New-Item -ItemType Directory -Path $target.path -Force | Out-Null;continue }
            New-Item -ItemType Directory -Path (Split-Path $target.path -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($target.entry,$target.path,$false)
        }
    } finally { $zip.Dispose() }
}
function Read-AtelierIntelInfSections {
    param([string]$Path)
    $sections=@{};$current=''
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line=($raw -split ';',2)[0].Trim()
        if ($line -match '^\[([^\]]+)\]$') {
            $current=$Matches[1]
            if (-not $sections.ContainsKey($current)) { $sections[$current]=New-Object Text.StringBuilder }
        } elseif ($current -and $line) { [void]$sections[$current].AppendLine($line) }
    }
    return $sections
}
function Get-AtelierIntelTargetVersion {
    param([string]$Decoration,[version]$WinPEVersion)
    $parts=$Decoration.Split('.')
    if ($parts[0] -ine 'NTamd64' -or $parts.Count -eq 2 -or $parts.Count -gt 6) { return }
    if ($parts.Count -eq 1) { return [version]'0.0.0' }
    if ($parts[1] -notmatch '^\d+$' -or $parts[2] -notmatch '^\d+$') { return }
    if ($parts.Count -ge 4 -and $parts[3] -notin @('','0','1')) { return }
    if ($parts.Count -ge 5 -and $parts[4] -notin @('','0')) { return }
    $build=0
    if ($parts.Count -eq 6 -and -not [int]::TryParse($parts[5],[ref]$build)) { return }
    $minimum=New-Object Version([int]$parts[1],[int]$parts[2],$build)
    if ($minimum -le $WinPEVersion) { return $minimum }
}
function Select-AtelierIntelI219Inf {
    param([string]$Path,[version]$WinPEVersion)
    $candidates=New-Object 'Collections.Generic.List[object]'
    foreach ($inf in Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.inf' -File) {
        # e1dn is NetAdapterCx, not the legacy NDIS e1d package wanted here.
        if ($inf.Name -notmatch '^e1d(?:6[0-9]x64)?\.inf$') { continue }
        $sections=Read-AtelierIntelInfSections $inf.FullName
        if (-not $sections.Version -or -not $sections.Manufacturer) { continue }
        $versionText=$sections.Version.ToString()
        if ($versionText -notmatch '(?im)^Class\s*=\s*"?Net"?\s*$' -or $versionText -notmatch '(?im)^DriverVer\s*=\s*[^,\r\n]+,\s*([0-9.]+)\s*$') { continue }
        $driverVersion=$null
        if (-not [version]::TryParse($Matches[1],[ref]$driverVersion)) { continue }
        $matchesHardware=$false;$targetVersion=$null
        foreach ($line in $sections.Manufacturer.ToString().Split("`n")) {
            if ($line -notmatch '^[^=]+=(.+)$') { continue }
            $parts=@($Matches[1].Split(',') | ForEach-Object { $_.Trim().Trim('"') })
            $models=New-Object 'Collections.Generic.List[object]'
            foreach ($decoration in $parts | Select-Object -Skip 1) {
                $minimum=Get-AtelierIntelTargetVersion -Decoration $decoration -WinPEVersion $WinPEVersion
                $section=$parts[0]+'.'+$decoration
                if ($null -ne $minimum -and $sections.ContainsKey($section)) { $models.Add([pscustomobject]@{minimum=$minimum;text=$sections[$section].ToString()}) }
            }
            $model=$models | Sort-Object minimum -Descending | Select-Object -First 1
            if ($model -and $model.text -match '(?im)^[^=\r\n]+=[^,\r\n]+,\s*"?PCI\\VEN_8086&DEV_15D7(?:[&",\s]|$)' -and $model.text -match '(?im)^[^=\r\n]+=[^,\r\n]+,\s*"?PCI\\VEN_8086&DEV_15D8(?:[&",\s]|$)') { $matchesHardware=$true;$targetVersion=$model.minimum;break }
        }
        if (-not $matchesHardware) { continue }
        # Keep the original directory; DISM resolves the INF's own file references.
        $catalog=$null
        foreach ($row in $versionText.Split("`n")) {
            if ($row -match '^CatalogFile(?:\.NTamd64)?\s*=\s*"?([^"\r\n]+?)"?\s*$') {
                $catalogName=$Matches[1].Trim()
                if ($catalogName -notmatch '[/\\:%]') { $catalog=Get-ChildItem -LiteralPath $inf.DirectoryName -File | Where-Object { $_.Name -ieq $catalogName } | Select-Object -First 1 }
                if ($catalog) { break }
            }
        }
        $binaries=@(Get-ChildItem -LiteralPath $inf.DirectoryName -Filter 'e1d*.sys' -File)
        if (-not $catalog -or -not $binaries.Count) { continue }
        $candidates.Add([pscustomobject]@{path=$inf.FullName;version=$driverVersion;minimum=$targetVersion})
    }
    $selected=$candidates | Sort-Object @{Expression='version';Descending=$true},@{Expression='minimum';Descending=$true},path | Select-Object -First 1
    if (-not $selected) { throw ('Aucun pilote NDIS Intel I219 x64 complet et compatible avec WinPE '+$WinPEVersion+' pour les identifiants 15D7 / 15D8. Aucun autre pilote importe.') }
    return $selected
}
function Get-AtelierIntelI219Driver {
    param([Parameter(Mandatory)][string]$CacheRoot,[Parameter(Mandatory)][version]$WinPEVersion)
    $url='https://downloadmirror.intel.com/923981/Wired_driver_31.2.2_x64.zip'
    $expectedHash='2cbff42aa02519e49f02d8e95a6572c44310e97fe67c42e299f2aba6ea9344f5'
    $cache=Join-Path $CacheRoot 'Intel-I219-31.2.2'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    Assert-AtelierIntelCachePath $cache
    $archive=Join-Path $cache 'Wired_driver_31.2.2_x64.zip'
    $partial=$archive+'.partial';$manifest=Join-Path $cache 'manifest.json';$drivers=Join-Path $cache 'drivers'
    $lock=$null;$staging=$null
    try {
        try { $lock=[IO.File]::Open((Join-Path $cache 'build.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'Le cache Intel WinPE est deja utilise par une autre construction.' }
        $archiveValid=(Test-Path $archive -PathType Leaf) -and (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedHash
        if (-not $archiveValid) {
            Write-Host 'Telechargement Intel Ethernet 31.2.2 : environ 39 Mo, conserve sur .250...'
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partial -TimeoutSec 300
            if ((Get-Item -LiteralPath $partial).Length -gt 100MB -or (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHash) { throw 'Empreinte SHA-256 Intel incorrecte. Aucun pilote importe.' }
            Move-Item -LiteralPath $partial -Destination $archive -Force
        }
        $valid=$false
        if ((Test-Path $manifest -PathType Leaf) -and (Test-Path $drivers -PathType Container)) {
            try {
                $saved=Get-Content -LiteralPath $manifest -Encoding UTF8 -Raw | ConvertFrom-Json
                $actual=@(Get-AtelierIntelTree $drivers);$expected=@($saved.files)
                $valid=$saved.sha256 -ceq $expectedHash -and $saved.source -ceq $url -and $actual.Count -gt 0 -and $actual.Count -eq $expected.Count
                if ($valid) { for ($i=0;$i -lt $actual.Count;$i++) { if ($actual[$i].name -cne $expected[$i].name -or $actual[$i].sha256 -cne $expected[$i].sha256) { $valid=$false;break } } }
            } catch { $valid=$false }
        }
        if (-not $valid) {
            $staging=Join-Path $cache ('extract-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $staging | Out-Null
            Expand-AtelierIntelArchive -Archive $archive -Destination $staging
            $files=@(Get-AtelierIntelTree $staging)
            Select-AtelierIntelI219Inf -Path $staging -WinPEVersion $WinPEVersion | Out-Null
            if (Test-Path $drivers) { Get-AtelierIntelTree $drivers | Out-Null;Remove-Item -LiteralPath $drivers -Recurse -Force }
            Move-Item -LiteralPath $staging -Destination $drivers;$staging=$null
            @{source=$url;sha256=$expectedHash;files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding UTF8
        }
        $selected=Select-AtelierIntelI219Inf -Path $drivers -WinPEVersion $WinPEVersion
        $result=[pscustomobject]@{network_infs=@($selected.path);family='Intel I219-LM/V';version=$selected.version.ToString();archive_version='31.2.2';source=$url;sha256=$expectedHash;winpe_version=$WinPEVersion.ToString();hardware_ids=@('PCI\VEN_8086&DEV_15D7','PCI\VEN_8086&DEV_15D8')}
        $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $cache 'selection.json') -Encoding UTF8
        Write-Host ('Reseau WinPE : 1 seul INF Intel I219 ('+[IO.Path]::GetFileName($selected.path)+', version '+$selected.version+').')
        return $result
    } finally {
        if ($lock) { try { if (Test-Path $partial) { Remove-Item -LiteralPath $partial -Force };if ($staging -and (Test-Path $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force } } finally { $lock.Dispose() } }
    }
}
