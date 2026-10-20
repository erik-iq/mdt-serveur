# Server-side preparation of the official HP WinPE x64 network drivers.
# Source: https://ftp.hp.com/pub/caps-softpaq/cmit/HP_WinPE_DriverPack.html
# Pack pinned to 3.40 / sp173204 (2026-06-22) for reproducible builds.
function Assert-AtelierWinPEHpSignature {
    param([string]$Path)
    $signature=Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)(?:CN|O)=(?:HP Inc\.|Hewlett-Packard Company)(?:,|$)') {
        throw 'Signature du pack WinPE HP refusee. Aucun pilote importe.'
    }
}
function Get-AtelierWinPEHpTree {
    param([string]$Path)
    $root=[IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    $directory=Get-Item -LiteralPath $Path
    while ($directory) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien interdit dans le cache WinPE HP.' }
        $directory=$directory.Parent
    }
    $items=@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Lien interdit dans le cache WinPE HP.' }
    foreach ($file in $items | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName) {
        [pscustomobject]@{name=$file.FullName.Substring($root.Length);sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
function Get-AtelierWinPEHpNetworkInfs {
    param([string]$Path)
    foreach ($inf in Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.inf' -File) {
        $content=Get-Content -LiteralPath $inf.FullName -Raw
        if ($content -notmatch '(?im)^\s*Class\s*=\s*"?Net"?\s*(?:;.*)?$') { continue }
        # IF_TYPE_IEEE80211=71, IF_TYPE_ETHERNET_CSMACD=6. Skip explicitly
        # wireless-only packages; an INF covering Ethernet too is retained.
        if ($content -match '(?im)^\s*\*IfType\s*=\s*(71|0x47)\s*(?:;.*)?$' -and $content -notmatch '(?im)^\s*\*IfType\s*=\s*(6|0x0?6)\s*(?:;.*)?$') { continue }
        $inf.FullName
    }
}
function Get-AtelierWinPEHpDrivers {
    param([Parameter(Mandatory)][string]$CacheRoot)
    $url='https://ftp.ext.hp.com/pub/softpaq/sp173001-173500/sp173204.exe'
    $cache=Join-Path $CacheRoot 'HP-sp173204'
    if ($cache -match '["\r\n]') { throw 'Chemin du cache WinPE HP invalide.' }
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    # Reject junctions before opening a package, lock or extraction under it.
    $directory=Get-Item -LiteralPath $cache
    while ($directory) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien interdit dans le cache WinPE HP.' }
        $directory=$directory.Parent
    }
    $package=Join-Path $cache 'sp173204.exe'
    $partial=Join-Path $cache 'sp173204.partial.exe'
    $drivers=Join-Path $cache 'drivers'
    $manifest=Join-Path $cache 'manifest.json'
    $lock=$null;$staging=$null
    try {
        try { $lock=[IO.File]::Open((Join-Path $cache 'build.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'Cache WinPE HP utilise par une autre construction.' }
        if (-not (Test-Path $package -PathType Leaf)) {
            Write-Host 'Telechargement du pack WinPE officiel HP 3.40 sur .250 (une seule fois)...'
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partial -TimeoutSec 1800
            $length=(Get-Item -LiteralPath $partial).Length
            if ($length -le 0 -or $length -gt 2GB) { throw 'Taille du pack WinPE HP invalide.' }
            Assert-AtelierWinPEHpSignature $partial
            Move-Item -LiteralPath $partial -Destination $package
        }
        Assert-AtelierWinPEHpSignature $package
        $hash=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
        $valid=$false
        if ((Test-Path $manifest -PathType Leaf) -and (Test-Path $drivers -PathType Container)) {
            try {
                $saved=Get-Content -LiteralPath $manifest -Encoding UTF8 -Raw | ConvertFrom-Json
                $actual=@(Get-AtelierWinPEHpTree $drivers);$expected=@($saved.files)
                $valid=$saved.source -ceq $url -and $saved.sha256 -ceq $hash -and $actual.Count -gt 0 -and $actual.Count -eq $expected.Count
                if ($valid) {
                    for ($i=0;$i -lt $actual.Count;$i++) {
                        if ($actual[$i].name -cne $expected[$i].name -or $actual[$i].sha256 -cne $expected[$i].sha256) { $valid=$false;break }
                    }
                }
            } catch { $valid=$false }
        }
        if (-not $valid) {
            $staging=Join-Path $cache ('extract-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $staging | Out-Null
            Write-Host 'Extraction silencieuse des pilotes WinPE ; aucune installation sur .250...'
            $process=$null
            try {
                $process=Start-Process -FilePath $package -ArgumentList ('/s /e /f "'+$staging+'"') -PassThru -NoNewWindow
                if (-not $process.WaitForExit(600000)) { $process.Kill();throw 'Extraction du pack WinPE HP trop longue.' }
                if ($process.ExitCode -ne 0) { throw ('Extraction WinPE HP en echec (code '+$process.ExitCode+').') }
            } finally { if ($process) { $process.Dispose() } }
            $files=@(Get-AtelierWinPEHpTree $staging)
            $infs=@(Get-AtelierWinPEHpNetworkInfs $staging)
            if (-not $infs.Count -or -not @($files | Where-Object { $_.name -match '\.sys$' }).Count -or -not @($files | Where-Object { $_.name -match '\.cat$' }).Count) { throw 'Pack HP incomplet : INF reseau, SYS ou CAT absents.' }
            if (Test-Path $drivers) {
                Get-AtelierWinPEHpTree $drivers | Out-Null
                Remove-Item -LiteralPath $drivers -Recurse -Force
            }
            Move-Item -LiteralPath $staging -Destination $drivers
            $staging=$null
            @{source=$url;softpaq='sp173204';version='3.40';sha256=$hash;files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding UTF8
        }
        $infs=@(Get-AtelierWinPEHpNetworkInfs $drivers)
        if (-not $infs.Count) { throw 'Aucun INF reseau dans le cache WinPE HP.' }
        Write-Host ('Pilotes reseau WinPE HP prets : '+$infs.Count+' INF ; cache et signature controles.')
        return [pscustomobject]@{path=$drivers;network_infs=$infs;softpaq='sp173204';version='3.40';source=$url;sha256=$hash}
    } finally {
        if ($lock) {
            try {
                if (Test-Path $partial) { Remove-Item -LiteralPath $partial -Force }
                if ($staging -and (Test-Path $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force }
            } finally { $lock.Dispose() }
        }
    }
}
