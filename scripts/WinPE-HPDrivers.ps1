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
function New-AtelierWinPEExtractionProcess {
    param([string]$Package,[string]$Destination)
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Package
    $start.Arguments='/s /e /f "'+$Destination+'"'
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    return $process
}
function Invoke-AtelierWinPEHpExtraction {
    param([string]$Package,[string]$Destination,[ValidateRange(1,600)][int]$TimeoutSeconds=600,[switch]$Defer1168Validation)
    # Windows PowerShell 5.1 Start-Process can return a Process whose ExitCode
    # stays null after WaitForExit. Own the process from creation through exit.
    $process=New-AtelierWinPEExtractionProcess -Package $Package -Destination $Destination
    try {
        if (-not $process.Start()) { throw 'Impossible de lancer l extracteur WinPE HP.' }
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw 'Extraction du pack WinPE HP trop longue.'
        }
        $exitCode=$process.ExitCode
        if ($null -eq $exitCode) { throw 'Code de sortie de l extracteur WinPE HP indisponible. Extraction non validee.' }
        # sp173204 may return 1168 after extracting. This is not a generic
        # success code: only the caller validating the fresh payload may defer it.
        if ($exitCode -ne 0 -and -not ($Defer1168Validation -and $exitCode -eq 1168)) { throw ('Extraction WinPE HP en echec (code '+$exitCode+').') }
        return $exitCode
    } finally { $process.Dispose() }
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
            $extractionExitCode=Invoke-AtelierWinPEHpExtraction -Package $package -Destination $staging -Defer1168Validation
            $files=@(Get-AtelierWinPEHpTree $staging)
            $infs=@(Get-AtelierWinPEHpNetworkInfs $staging)
            $sysCount=@($files | Where-Object { $_.name -match '\.sys$' }).Count
            $catCount=@($files | Where-Object { $_.name -match '\.cat$' }).Count
            $complete=$infs.Count -gt 0 -and $sysCount -gt 0 -and $catCount -gt 0
            $extractionLog=Join-Path $cache 'extraction-result.json'
            @{softpaq='sp173204';exit_code=$extractionExitCode;files=$files.Count;network_infs=$infs.Count;sys_files=$sysCount;cat_files=$catCount;payload_present=$complete;utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $extractionLog -Encoding UTF8
            if (-not $complete) { throw ('Pack HP incomplet apres extraction (code '+$extractionExitCode+') : INF reseau='+$infs.Count+', SYS='+$sysCount+', CAT='+$catCount+'. Diagnostic : '+$extractionLog) }
            if ($extractionExitCode -eq 1168) { Write-Host 'Code HP 1168 : contenu reseau present ; verification des pilotes par DISM a suivre.' }
            if (Test-Path $drivers) {
                Get-AtelierWinPEHpTree $drivers | Out-Null
                Remove-Item -LiteralPath $drivers -Recurse -Force
            }
            Move-Item -LiteralPath $staging -Destination $drivers
            $staging=$null
            @{source=$url;softpaq='sp173204';version='3.40';sha256=$hash;files=$files;extraction_exit_code=$extractionExitCode} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding UTF8
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
