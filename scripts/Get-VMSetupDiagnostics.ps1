#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='VM')]
param(
    [Parameter(ParameterSetName='VM')][string]$VMName = 'PC-TEST-PXE',
    [Parameter(Mandatory,ParameterSetName='Directory')][string]$WindowsPath,
    [string]$OutputPath = (Join-Path ([IO.Path]::GetTempPath()) ('AtelierPXE-Diagnostic-' + [guid]::NewGuid().ToString('N'))),
    [switch]$OpenFolder
)
$ErrorActionPreference = 'Stop'
$mountedPath = $null
$isWindowsHost = $env:OS -eq 'Windows_NT'

function Get-AnswerFileSummary {
    param([string]$Path)
    $summary = [ordered]@{exists=[IO.File]::Exists($Path); size_bytes=0; encoding='unknown'; xml_valid=$false; reason='missing'}
    if (-not $summary.exists) { return $summary }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $summary.size_bytes = $bytes.Length
    $zeroBytes = 0
    foreach ($value in $bytes) { if ($value -eq 0) { $zeroBytes++ } }
    $summary.zero_bytes = $zeroBytes
    $summary.all_bytes_zero = $bytes.Length -gt 0 -and $zeroBytes -eq $bytes.Length
    if ($bytes.Length -eq 0) { $summary.reason='empty'; return $summary }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) { $summary.encoding='UTF-32 LE BOM' }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) { $summary.encoding='UTF-32 BE BOM' }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $summary.encoding='UTF-8 BOM' }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $summary.encoding='UTF-16 LE BOM' }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $summary.encoding='UTF-16 BE BOM' }
    $stream = New-Object IO.MemoryStream(,$bytes)
    $reader = $null
    try {
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($stream,$settings)
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        $summary.xml_valid = $true
        $summary.reason = 'well_formed_xml'
        $summary.root = $document.DocumentElement.LocalName
        $summary.namespace = $document.DocumentElement.NamespaceURI
        # Well-formed XML is not proof of acceptance by Windows Setup/WSIM.
        $summary.windows_validation = 'not_performed'
    } catch {
        $summary.reason = 'invalid_xml'
        $exception = $_.Exception
        while ($exception.InnerException -and $exception -isnot [Xml.XmlException]) { $exception=$exception.InnerException }
        if ($exception -is [Xml.XmlException]) { $summary.error_line=$exception.LineNumber; $summary.error_position=$exception.LinePosition }
        # Do not put XML snippets or exception messages into the public summary.
    } finally {
        if ($reader) { $reader.Dispose() }
        $stream.Dispose()
    }
    return $summary
}

try {
    if ($isWindowsHost) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Ouvrez Windows PowerShell en administrateur.' }
    }
    if ($PSCmdlet.ParameterSetName -eq 'VM') {
        if (-not $isWindowsHost) { throw 'Le mode VM necessite l hote Hyper-V Windows.' }
        Import-Module Hyper-V -ErrorAction Stop
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ($vm.State -ne 'Off') { throw "Eteignez uniquement la VM $VMName depuis Hyper-V, puis relancez la collecte." }
        $drives = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop)
        if ($drives.Count -ne 1 -or -not $drives[0].Path) { throw 'La collecte automatique attend un seul disque virtuel. Verifiez les disques de la VM.' }
        $diskPath = $drives[0].Path
        $vhd = Get-VHD -Path $diskPath -ErrorAction Stop
        if ($vhd.Attached) { throw 'Le disque virtuel est deja attache. Aucun montage ni demontage effectue.' }
        $image = Mount-VHD -Path $diskPath -ReadOnly -NoDriveLetter -Passthru -ErrorAction Stop
        $mountedPath = $diskPath
        Update-HostStorageCache -ErrorAction Stop
        $disk = Get-Disk -Number $image.DiskNumber -ErrorAction Stop
        if (-not $disk.IsReadOnly -or $disk.IsOffline) { throw 'Le disque monte doit etre en ligne et en lecture seule. Aucun changement de son etat ne sera effectue.' }
        $roots = @()
        foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)) {
            foreach ($path in @($partition.AccessPaths)) {
                if ($path -match '^\\\\\?\\Volume\{[0-9a-f-]{36}\}\\$' -and [IO.File]::Exists($path + 'Windows\System32\Config\SYSTEM')) {
                    $roots += ($path + 'Windows')
                }
            }
        }
        $roots = @($roots | Select-Object -Unique)
        if ($roots.Count -ne 1) { throw 'Impossible d identifier une unique installation Windows accessible sur ce disque. Aucun fichier source modifie.' }
        $WindowsPath = $roots[0]
    }
    if (-not [IO.Directory]::Exists($WindowsPath)) { throw 'Dossier Windows introuvable.' }
    $destination = [IO.Path]::GetFullPath($OutputPath)
    $sourceRoot = [IO.Path]::GetFullPath($WindowsPath).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if ($destination -eq $sourceRoot -or $destination.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Placez le rapport hors du dossier Windows source.'
    }
    if (Test-Path -LiteralPath $destination) { throw 'Le dossier de sortie existe deja. Utilisez un nouveau chemin.' }
    New-Item -ItemType Directory -Path $destination | Out-Null
    if ($isWindowsHost) {
        $userGrant = '*' + $identity.User.Value + ':(OI)(CI)F'
        & icacls.exe $destination /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' $userGrant | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Impossible de proteger le dossier de diagnostic.' }
    }
    $report = [ordered]@{utc=[DateTime]::UtcNow.ToString('o'); answer_files=@(); logs=@()}
    # Use fixed paths only, without a recursive search or following junctions.
    $files = @(
        @('Panther','setuperr.log'), @('Panther','setupact.log'),
        @('Panther','UnattendGC','setuperr.log'), @('Panther','UnattendGC','setupact.log'),
        @('System32','Sysprep','Panther','setuperr.log'), @('System32','Sysprep','Panther','setupact.log'),
        @('Panther','unattend.xml'), @('Panther','Unattend','unattend.xml')
    )
    foreach ($segments in $files) {
        $source = $WindowsPath
        $reparse = $false
        foreach ($segment in $segments) {
            $source = [IO.Path]::Combine($source,$segment)
            if (([IO.File]::Exists($source) -or [IO.Directory]::Exists($source)) -and ([IO.File]::GetAttributes($source) -band [IO.FileAttributes]::ReparsePoint)) { $reparse=$true; break }
        }
        $name = $segments -join '-'
        if ($reparse) { $report.logs += @{file=$name; exists=$false; reason='reparse_point_refused'}; continue }
        if ($segments[-1] -eq 'unattend.xml') {
            $summary = Get-AnswerFileSummary -Path $source
            $summary.file = $name
            $report.answer_files += $summary
        } else {
            $exists = [IO.File]::Exists($source)
            $report.logs += @{file=$name; exists=$exists; size_bytes=$(if ($exists) { (New-Object IO.FileInfo($source)).Length } else { 0 })}
        }
        if ([IO.File]::Exists($source)) { [IO.File]::Copy($source,([IO.Path]::Combine($destination,$name)),$false) }
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $destination 'diagnostic.json') -Encoding UTF8
    Write-Host "Diagnostic copie dans : $destination" -ForegroundColor Green
    foreach ($answer in $report.answer_files) { Write-Host ("{0} : existe={1}, taille={2} octets, XML={3}, encodage={4}" -f $answer.file,$answer.exists,$answer.size_bytes,$answer.xml_valid,$answer.encoding) }
} finally {
    # Only detach the image mounted by this invocation, even after a copy error.
    if ($mountedPath) { Dismount-VHD -Path $mountedPath -ErrorAction Stop }
}
if ($OpenFolder -and $isWindowsHost) { Start-Process explorer.exe -ArgumentList ('"' + $destination + '"') | Out-Null }
