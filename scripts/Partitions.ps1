# Functions only. Loading this file never partitions or formats a disk.
function Get-AtelierVolumeGuid {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter)
    # The storage provider can omit DriveLetter on an ESP. Resolve the actual
    # DOS mount to a volume GUID, then compare it with the target's AccessPaths.
    $result = & mountvol.exe "${DriveLetter}:\" /L 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Volume ${DriveLetter}: non accessible (mountvol : $LASTEXITCODE)." }
    $paths = @($result | ForEach-Object { ([string]$_).Trim() } | Where-Object {
        $_ -match '^\\\\\?\\Volume\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}\\$'
    } | Select-Object -Unique)
    if ($paths.Count -ne 1) { throw "Impossible d identifier le volume de ${DriveLetter}:." }
    return $paths[0]
}

function Get-AtelierVolumeIdentity {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter)
    $path = Get-AtelierVolumeGuid -DriveLetter $DriveLetter
    $drive = New-Object IO.DriveInfo("${DriveLetter}:\")
    if (-not $drive.IsReady) { throw "Volume ${DriveLetter}: non pret." }
    return [pscustomobject]@{Path=$path; FileSystem=$drive.DriveFormat}
}

function Wait-AtelierTargetPartitions {
    param(
        [Parameter(Mandatory)][ValidateRange(0,2147483647)][int]$DiskNumber,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedUniqueId,
        [Parameter(Mandatory)][UInt64]$ExpectedSize,
        [ValidateRange(1,60)][int]$Attempts = 20,
        [ValidateRange(0,2000)][int]$RetryDelayMilliseconds = 500
    )
    $expected = @(
        @{Number=1; Type='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'; Letter='S'; FileSystem='FAT32'; MinSize=260MB},
        @{Number=2; Type='e3c9e316-0b5c-4db8-817d-f92df00215ae'; Letter=''; FileSystem=''; MinSize=16MB},
        @{Number=3; Type='ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'; Letter='W'; FileSystem='NTFS'; MinSize=1GB},
        @{Number=4; Type='de94bba4-06d1-4d40-a16a-bfd50179d6ac'; Letter='R'; FileSystem='NTFS'; MinSize=990MB}
    )
    $lastReason = 'Inventaire des partitions indisponible.'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Update-HostStorageCache -ErrorAction Stop
            $currentDisk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        } catch { throw "Impossible de verifier le disque cible apres DiskPart : $($_.Exception.Message)" }
        # A different disk is a hard failure, never a reason to repair mounts.
        if ($currentDisk.Number -ne $DiskNumber -or $currentDisk.UniqueId -ne $ExpectedUniqueId -or $currentDisk.Size -ne $ExpectedSize) {
            throw 'L identite du disque cible a change apres DiskPart. Application de Windows refusee.'
        }
        try {
            if ($currentDisk.PartitionStyle -ne 'GPT') { throw 'Le disque cible n est pas GPT.' }
            $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)
            if ($partitions.Count -ne 4) { throw "Quatre partitions attendues sur le disque $DiskNumber ; $($partitions.Count) detectees." }
            foreach ($spec in $expected) {
                $matches = @($partitions | Where-Object { $_.PartitionNumber -eq $spec.Number })
                if ($matches.Count -ne 1) { throw "Partition $($spec.Number) absente ou ambigue." }
                $partition = $matches[0]
                if ($partition.DiskNumber -ne $DiskNumber -or [Guid]$partition.GptType -ne [Guid]$spec.Type -or $partition.Size -lt $spec.MinSize) {
                    throw "Partition $($spec.Number) : disque, type GPT ou taille incorrects."
                }
                if ($spec.Letter) {
                    $volume = Get-AtelierVolumeIdentity -DriveLetter $spec.Letter
                    $paths = @($partition.AccessPaths | ForEach-Object { ([string]$_).TrimEnd('\') })
                    if (([string]$volume.Path).TrimEnd('\') -notin $paths) {
                        throw "Le volume $($spec.Letter): ne correspond pas a la partition $($spec.Number) du disque $DiskNumber."
                    }
                    if ($volume.FileSystem -ne $spec.FileSystem) { throw "Volume $($spec.Letter): attendu en $($spec.FileSystem), detecte en $($volume.FileSystem)." }
                }
            }
            return
        } catch { $lastReason = $_.Exception.Message }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
    }
    throw "Partitionnement non valide apres $Attempts controles : $lastReason Application de Windows refusee."
}
