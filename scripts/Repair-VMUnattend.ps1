#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$VMName = 'PC-TEST-PXE',
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,14}$')][string]$ComputerName,
    [string]$Locale = 'fr-FR',
    [string]$BackupPath = (Join-Path $env:TEMP ('AtelierPXE-Reparation-' + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Unattend.ps1')
Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne 'Off') { throw "La VM $VMName doit etre arretee avant la reparation." }
$drives = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop)
if ($drives.Count -ne 1 -or -not $drives[0].Path) { throw 'Un unique disque virtuel est requis pour cette reparation.' }
$diskPath = $drives[0].Path
if ((Get-VHD -Path $diskPath -ErrorAction Stop).Attached) { throw 'Le disque virtuel est deja attache. Reparation interrompue.' }
if (Test-Path -LiteralPath $BackupPath) { throw 'Utilisez un nouveau dossier de sauvegarde.' }
New-Item -ItemType Directory -Path $BackupPath | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$userGrant = '*' + $identity.User.Value + ':(OI)(CI)F'
& icacls.exe $BackupPath /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' $userGrant | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Impossible de proteger la sauvegarde.' }
$mounted = $false
try {
    $image = Mount-VHD -Path $diskPath -NoDriveLetter -Passthru -ErrorAction Stop
    $mounted = $true
    Update-HostStorageCache -ErrorAction Stop
    $disk = Get-Disk -Number $image.DiskNumber -ErrorAction Stop
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.IsOffline -or $disk.IsReadOnly) { throw 'Le disque monte n est pas une cible de reparation accessible.' }
    $roots = @()
    foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)) {
        foreach ($path in @($partition.AccessPaths)) {
            if ($path -match '^\\\\\?\\Volume\{[0-9a-f-]{36}\}\\$' -and [IO.File]::Exists($path + 'Windows\System32\Config\SYSTEM')) { $roots += ($path + 'Windows') }
        }
    }
    $roots = @($roots | Select-Object -Unique)
    if ($roots.Count -ne 1) { throw 'Impossible d identifier une unique installation Windows sur le disque de la VM.' }
    $report = Repair-AtelierOfflineUnattend -WindowsPath $roots[0] -ComputerName $ComputerName -Locale $Locale -BackupDirectory $BackupPath
    Write-Host ('Fichier de reponses remplace et verifie : ' + $report.size_bytes + ' octets ; SHA-256 ' + $report.sha256) -ForegroundColor Green
    Write-Host "Sauvegarde de l original et rapport : $BackupPath"
} finally { if ($mounted) { Dismount-VHD -Path $diskPath -ErrorAction Stop } }
Write-Host 'La VM reste arretee. Demarrez-la sur Windows Boot Manager pour verifier la reprise du premier demarrage.'
