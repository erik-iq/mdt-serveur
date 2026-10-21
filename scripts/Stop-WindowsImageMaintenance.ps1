#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,[Parameter(Mandatory)][ValidatePattern('^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$')][string]$RunId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
. (Join-Path $PSScriptRoot 'Windows-ImageServicing.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content -LiteralPath (Join-Path $InstallPath 'data-runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$root=Assert-AtelierServicingPath (Join-Path $config.data_dir 'windows-servicing')
$run=Assert-AtelierServicingPath (Join-Path (Join-Path $root 'runs') $RunId)
$reportPath=Assert-AtelierServicingPath (Join-Path $run 'report.json')
$report=Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$candidate=Assert-AtelierServicingPath (Join-Path $run 'candidate.wim')
$mount=Assert-AtelierServicingPath (Join-Path $run 'mount')
if ($report.run_id -ne $RunId -or [IO.Path]::GetFullPath([string]$report.candidate_path) -ne $candidate -or
    [IO.Path]::GetFullPath([string]$report.source_path) -eq $candidate -or
    $report.status -notin @('preparing','failed_cleanup_required','cancelled_cleanup_required','cancelled')) {
    throw 'Cette execution n est pas une preparation candidate annulable. Aucun processus arrete.'
}

function Get-AtelierCandidateDism {
    # Match full argument values, never a global process name or a stale PID.
    @(Get-CimInstance Win32_Process -Filter "Name='dism.exe'" | Where-Object {
        $matchesCandidate=$false
        foreach ($argument in [regex]::Matches([string]$_.CommandLine,'(?i)(?:^|\s)/(?:MountDir|Image|ImageFile):(?:"(?<value>[^"]+)"|(?<value>\S+))')) {
            $path=[IO.Path]::GetFullPath($argument.Groups['value'].Value).TrimEnd([char[]]'\/')
            if ($path -eq $mount -or $path -eq $candidate) { $matchesCandidate=$true }
        }
        $matchesCandidate
    })
}
function Get-AtelierCandidateMount {
    $entries=@(Get-WindowsImage -Mounted | Where-Object { [IO.Path]::GetFullPath([string]$_.Path).TrimEnd([char[]]'\/') -eq $mount })
    if (@($entries | Where-Object { [IO.Path]::GetFullPath([string]$_.ImagePath) -ne $candidate }).Count) {
        throw 'Ce point de montage appartient a une autre image. Aucun demontage autorise.'
    }
    return $entries
}
$taskName='AtelierPXE-WindowsImageMaintenance'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$scriptPath=Join-Path $InstallPath 'scripts\Update-WindowsImage.ps1'
if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Arguments -notlike ('*"'+$scriptPath+'"*')) {
    throw 'La tache ne correspond pas a cette console. Aucun processus arrete.'
}
Get-AtelierCandidateMount | Out-Null
# CIM can return a single scalar without a usable Count property in PS 5.1.
# Count the collection, not a property on the native process object.
$active=@(Get-AtelierCandidateDism)
if ($task.State -eq 'Running' -and -not $active.Count) {
    throw 'Aucun DISM actif ne correspond a cette execution. Relire le journal pour identifier l execution courante avant de l annuler.'
}

# Pause future triggers before stopping the owner. No production image is written.
Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
if ($task.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $deadline=(Get-Date).AddSeconds(15)
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        if ((Get-Date) -gt $deadline) { throw 'La tache ne s arrete pas. Aucun processus DISM arrete manuellement.' }
        Start-Sleep -Milliseconds 250
    }
}
$held=$null
try {
    # Exclude a second maintenance or console upgrade during mount recovery.
    $held=[IO.File]::Open((Join-Path $root 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $report.status='cancelled_cleanup_required'
    $report | Add-Member NoteProperty cancelled_at ([DateTime]::UtcNow.ToString('o')) -Force
    $report | Add-Member NoteProperty error 'Preparation annulee par l operateur ; copie candidate abandonnee. Image de production non modifiee.' -Force
    Write-AtelierServicingJson $report $reportPath
    foreach ($process in @(Get-AtelierCandidateDism)) {
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$process.ProcessId)
        if ($current -and $current.CreationDate -eq $process.CreationDate -and $current.CommandLine -eq $process.CommandLine) {
            Write-Host ('Arret du DISM de la copie candidate uniquement : '+$process.ProcessId)
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
    }
    $deadline=(Get-Date).AddSeconds(15)
    while (@(Get-AtelierCandidateDism).Count) {
        if ((Get-Date) -gt $deadline) { throw 'DISM encore actif ; ne pas relancer la maintenance ni la mise a jour de la console.' }
        Start-Sleep -Milliseconds 250
    }
    if (@(Get-AtelierCandidateMount).Count) {
        Write-Host 'Demontage de la copie candidate avec abandon des changements...'
        Dismount-WindowsImage -Path $mount -Discard -LogPath (Join-Path $run 'cancel-discard.log') -ErrorAction Stop | Out-Null
    }
    if (@(Get-AtelierCandidateMount).Count) { throw 'Montage encore present ; journaux et copie candidate conserves pour recuperation.' }
    if (Test-Path -LiteralPath $candidate) {
        $probe=[IO.File]::Open($candidate,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        $probe.Dispose()
    }
    $report.status='cancelled'
    Write-AtelierServicingJson $report $reportPath
    Write-Host 'Maintenance annulee et montage libere. Planification en pause.' -ForegroundColor Green
    Write-Host 'Image Windows originale, sauvegardes, cache et journaux conserves. La copie candidate annulee ne doit pas etre utilisee.'
} finally { if ($held) { $held.Dispose() } }
