# CMSL acquisition only. Never execute a downloaded SoftPaq on the server.
function Assert-AtelierHpTree {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $parent=$item
    while ($parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien refuse dans le depot HP.' }
        $parent=$parent.Parent
    }
    $stack=New-Object 'Collections.Generic.Stack[string]';$stack.Push($item.FullName)
    while ($stack.Count) {
        foreach ($child in @(Get-ChildItem -LiteralPath $stack.Pop() -Force)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien refuse dans le depot HP.' }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) }
        }
    }
}
function Get-AtelierHpCmslCommand {
    param([string]$Name)
    foreach ($candidate in @($Name,($Name -replace '-HPRepository','-Repository'))) {
        $command=Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command -and $command.ModuleName -match '^(HP\.|HPCMSL)') { return $command }
    }
    throw ('Commande CMSL absente : '+$Name+'. Installer HPCMSL sur le serveur.')
}
function Get-AtelierHpFreeSpace {
    param([string]$Path)
    $drive=(Get-Item -LiteralPath $Path).PSDrive
    if ($null -eq $drive.Free) { return [long]::MaxValue }
    return [long]$drive.Free
}
function Test-AtelierHpRepositoryFile {
    param([string]$Name)
    if ($Name.Length -gt 240 -or $Name -match '(^|/)(\.|\.\.)(/|$)' -or $Name -match '[^A-Za-z0-9_. /-]') { return $false }
    if ($Name -match '(?i)^sp[0-9]{4,8}\.(exe|cva|html)$') { return $true }
    return $Name -cmatch '^\.repository/cache/[^:]+\.(cab|xml|json|cva|html|txt)$'
}
function Sync-AtelierHpRepository {
    param([string]$DataRoot,$Job)
    if ([string]$Job.id -notmatch '^[a-f0-9-]{36}$' -or [string]$Job.platform -notmatch '^[A-F0-9]{4}$' -or
        $Job.os -notin @('win10','win11') -or [string]$Job.os_version -notmatch '^([12][0-9]H[12]|1809|1903|1909|2004|2009)$') { throw 'Demande de depot HP invalide.' }
    $identifier=[guid]::Parse([string]$Job.id).ToString()
    $root=Join-Path $DataRoot 'hp-repository'
    $work=Join-Path $root ('work\'+$Job.platform+'\'+$Job.os+'-'+$Job.os_version)
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Assert-AtelierHpTree $root
    if ((Get-AtelierHpFreeSpace $work) -lt 4GB) { throw 'Depot HP reporte : moins de 4 Go libres sur le serveur.' }
    $owner=Join-Path $work 'atelier-owner.json'
    if (Test-Path $owner) {
        $previous=Get-Content $owner -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($previous.platform -ne $Job.platform -or $previous.os -ne $Job.os -or $previous.os_version -ne $Job.os_version) { throw 'Dossier CMSL affecte a une autre plateforme.' }
    } elseif (@(Get-ChildItem -LiteralPath $work -Force).Count) { throw 'Dossier CMSL non identifie ; aucun contenu remplace.' }
    @{platform=$Job.platform;os=$Job.os;os_version=$Job.os_version} | ConvertTo-Json | Set-Content $owner -Encoding UTF8
    Push-Location $work
    try {
        # Recreate only owned metadata; keep downloaded EXEs so CMSL can reuse
        # them. Published snapshots never point into this mutable directory.
        $metadata=Join-Path $work '.repository'
        if (Test-Path $metadata) { Remove-Item -LiteralPath $metadata -Recurse -Force }
        & (Get-AtelierHpCmslCommand 'Initialize-HPRepository') | Out-Null
        & (Get-AtelierHpCmslCommand 'Set-HPRepositoryConfiguration') -Setting OfflineCacheMode -CacheValue Enable | Out-Null
        & (Get-AtelierHpCmslCommand 'Add-HPRepositoryFilter') -Platform $Job.platform -Os $Job.os -OsVer $Job.os_version -Category @('Bios','Firmware','Driver','Software','Manageability','Diagnostic','Utility','Dock','UWPPack') | Out-Null
        & (Get-AtelierHpCmslCommand 'Invoke-HPRepositorySync') -Quiet | Out-Null
        Assert-AtelierHpTree $work
        & (Get-AtelierHpCmslCommand 'Invoke-HPRepositoryCleanup') | Out-Null
        Assert-AtelierHpTree $work
        $files=New-Object 'Collections.Generic.List[object]'
        foreach ($file in @(Get-ChildItem -LiteralPath $work -Recurse -Force -File)) {
            $relative=$file.FullName.Substring($work.TrimEnd([char[]]'\/').Length+1).Replace('\','/')
            if (-not (Test-AtelierHpRepositoryFile $relative)) { continue }
            if ($relative -match '(?i)\.exe$') {
                $signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(HP Inc\.|Hewlett-Packard)') {
                    # Remove this invalid working copy so the next CMSL sync
                    # downloads it again. Published archives remain untouched.
                    Remove-Item -LiteralPath $file.FullName -Force
                    throw ('Signature SoftPaq invalide : '+$file.Name+' ; copie de travail retiree pour une prochaine tentative.')
                }
            }
            $files.Add(@{name=$relative;path=$file.FullName;length=$file.Length})
        }
        if (-not @($files | Where-Object { $_.name -match '(?i)^\.repository/cache/.*/?platformList\.cab$|^\.repository/cache/platformList\.cab$' }).Count -or
            -not @($files | Where-Object { [IO.Path]::GetFileName($_.name) -like ($Job.platform+'_*.cab') }).Count) { throw 'References HP hors ligne incompletes ; depot non publie.' }
        $total=($files | Measure-Object -Property length -Sum).Sum
        if ($total -gt 20GB -or $files.Count -gt 5000) { throw 'Depot HP trop volumineux pour cette plateforme.' }
        if ((Get-AtelierHpFreeSpace $work) -lt ($total+2GB)) { throw 'Depot HP reporte : espace insuffisant pour publier une nouvelle copie.' }
        $snapshots=Join-Path $root 'snapshots';New-Item -ItemType Directory -Path $snapshots -Force | Out-Null
        $target=Join-Path $snapshots ($identifier+'.zip')
        $temporary=$target+'.partial'
        if (Test-Path $target) { throw 'Archive HP deja publiee ; aucune modification autorisee.' }
        Add-Type -AssemblyName System.IO.Compression
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::Create)
        $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in @($files | Sort-Object name)) {
                # SoftPaqs/CABs are already compressed. Avoid CPU-heavy recompression.
                $entry=$zip.CreateEntry($file.name,[IO.Compression.CompressionLevel]::NoCompression)
                $input=[IO.File]::OpenRead($file.path);$output=$entry.Open()
                try { $input.CopyTo($output) } finally { $input.Dispose();$output.Dispose() }
            }
        } finally { $zip.Dispose();$stream.Dispose() }
        if ((Get-Item $temporary).Length -gt 20GB) { throw 'Archive HP trop volumineuse.' }
        Move-Item -LiteralPath $temporary -Destination $target
        return @{id=$identifier;platform=$Job.platform;os=$Job.os;os_version=$Job.os_version;size=(Get-Item $target).Length}
    } finally { Pop-Location }
}
