#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,[ValidatePattern('^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$')][string]$RunId,[switch]$IfActive)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
. (Join-Path $PSScriptRoot 'Windows-ImageServicing.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content -LiteralPath (Join-Path $InstallPath 'data-runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$root=Assert-AtelierServicingPath (Join-Path $config.data_dir 'windows-servicing')
function Get-AtelierPreDismOwner {
    param($Report,[string]$Candidate)
    if ($Report.status -ne 'preparing' -or $Report.active_stage -notin @('verify_source','read_metadata','backup','catalog_download','verify_hash','commit','mount','export_fast') -or
        -not $Report.started_at) { return }
    $owner=Get-ScheduledTask -TaskName 'AtelierPXE-WindowsImageMaintenance' -ErrorAction Stop
    $scriptPath=Join-Path $InstallPath 'scripts\Update-WindowsImage.ps1'
    if ($owner.State -ne 'Running' -or @($owner.Actions).Count -ne 1 -or
        $owner.Actions[0].Arguments -notlike ('*"'+$scriptPath+'"*')) { return }
    $taskInfo=Get-ScheduledTaskInfo -TaskName 'AtelierPXE-WindowsImageMaintenance' -ErrorAction Stop
    $start=([datetime]$taskInfo.LastRunTime).ToUniversalTime()
    if (([datetime]$Report.started_at).ToUniversalTime() -lt $start.AddSeconds(-5)) { return }
    $scriptArgument='(?i)(?:^|\s)-File\s+(?:"'+[regex]::Escape($scriptPath)+'"|'+[regex]::Escape($scriptPath)+'(?=\s|$))'
    $installArgument='(?i)(?:^|\s)-InstallPath\s+(?:"'+[regex]::Escape($InstallPath)+'"|'+[regex]::Escape($InstallPath)+'(?=\s|$))'
    $processes=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -match $scriptArgument -and $_.CommandLine -match $installArgument -and
        $_.CreationDate -and [math]::Abs((([datetime]$_.CreationDate).ToUniversalTime()-$start).TotalSeconds) -le 30
    })
    if ($processes.Count -ne 1) { return }
    if ($Report.worker_pid -and ([int]$Report.worker_pid -ne [int]$processes[0].ProcessId -or
        [math]::Abs((([datetime]$Report.worker_started_at).ToUniversalTime()-([datetime]$processes[0].CreationDate).ToUniversalTime()).TotalSeconds) -ge 1)) { return }
    return $processes[0]
}

if (-not $RunId) {
    $prefix=(Join-Path $root 'runs').TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    $pattern='(?i)^'+[regex]::Escape($prefix)+'(?<run>[0-9]{8}-[0-9]{6}-[a-f0-9]{8})[\\/](?:mount|candidate\.wim)$'
    $found=@(
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='dism.exe'")) {
            foreach ($argument in [regex]::Matches([string]$process.CommandLine,'(?i)(?:^|\s)/(?:MountDir|Image|ImageFile|DestinationImageFile):(?:"(?<value>[^"]+)"|(?<value>\S+))')) {
                $match=[regex]::Match([IO.Path]::GetFullPath($argument.Groups['value'].Value).TrimEnd([char[]]'\/'),$pattern)
                if ($match.Success) { $match.Groups['run'].Value }
            }
        }
        foreach ($image in @(Get-WindowsImage -Mounted)) {
            $match=[regex]::Match([string]$image.ImagePath,$pattern)
            if ($match.Success) { $match.Groups['run'].Value }
        }
    )
    $found=@($found | Sort-Object -Unique)
    $owner=Get-ScheduledTask -TaskName 'AtelierPXE-WindowsImageMaintenance' -ErrorAction SilentlyContinue
    if (-not $found.Count -and $IfActive -and $owner.State -ne 'Running') { Write-Host 'Aucune maintenance WIM active à annuler.';return }
    if (-not $found.Count -and $owner.State -eq 'Running') {
        # Avant le premier DISM, corréler le rapport, la tâche et son processus exact.
        $found=@(foreach ($directory in @(Get-ChildItem -LiteralPath (Join-Path $root 'runs') -Directory)) {
            if ($directory.Name -notmatch '^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$') { continue }
            $path=Assert-AtelierServicingPath (Join-Path $directory.FullName 'report.json')
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $value=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $expected=Assert-AtelierServicingPath (Join-Path $directory.FullName 'candidate.wim')
            if ($value.run_id -eq $directory.Name -and [string]$value.candidate_path -eq $expected -and
                (Get-AtelierPreDismOwner -Report $value -Candidate $expected)) { $directory.Name }
        })
    }
    if ($found.Count -ne 1) { throw 'Exécution WIM non identifiable ou ambiguë. Aucun processus arrêté ; fournir le RunId courant du journal.' }
    $RunId=$found[0]
}
$run=Assert-AtelierServicingPath (Join-Path (Join-Path $root 'runs') $RunId)
$reportPath=Assert-AtelierServicingPath (Join-Path $run 'report.json')
$report=Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$candidate=Assert-AtelierServicingPath (Join-Path $run 'candidate.wim')
$mount=Assert-AtelierServicingPath (Join-Path $run 'mount')
if ($report.run_id -ne $RunId -or [IO.Path]::GetFullPath([string]$report.candidate_path) -ne $candidate -or
    [IO.Path]::GetFullPath([string]$report.source_path) -eq $candidate -or
    $report.status -notin @('preparing','failed_cleanup_required','cancelled_cleanup_required','cancelled')) {
    throw 'Cette exécution n''est pas une préparation candidate annulable. Aucun processus arrêté.'
}

function Get-AtelierCandidateDism {
    # Comparer les arguments complets, sans nom global de processus ni ancien PID.
    @(Get-CimInstance Win32_Process -Filter "Name='dism.exe'" | Where-Object {
        $matchesCandidate=$false
        foreach ($argument in [regex]::Matches([string]$_.CommandLine,'(?i)(?:^|\s)/(?:MountDir|Image|ImageFile|DestinationImageFile):(?:"(?<value>[^"]+)"|(?<value>\S+))')) {
            $path=[IO.Path]::GetFullPath($argument.Groups['value'].Value).TrimEnd([char[]]'\/')
            if ($path -eq $mount -or $path -eq $candidate) { $matchesCandidate=$true }
        }
        $matchesCandidate
    })
}
function Get-AtelierCandidateMount {
    $entries=@(Get-WindowsImage -Mounted | Where-Object { [IO.Path]::GetFullPath([string]$_.Path).TrimEnd([char[]]'\/') -eq $mount })
    if (@($entries | Where-Object { [IO.Path]::GetFullPath([string]$_.ImagePath) -ne $candidate }).Count) {
        throw 'Ce point de montage appartient à une autre image. Aucun démontage autorisé.'
    }
    return $entries
}
$taskName='AtelierPXE-WindowsImageMaintenance'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$scriptPath=Join-Path $InstallPath 'scripts\Update-WindowsImage.ps1'
if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Arguments -notlike ('*"'+$scriptPath+'"*')) {
    throw 'La tâche ne correspond pas à cette console. Aucun processus arrêté.'
}
Get-AtelierCandidateMount | Out-Null
# CIM peut renvoyer un scalaire sans propriété Count utilisable sous PowerShell 5.1.
# Compter la collection, sans lire une propriété de l’objet natif.
$active=@(Get-AtelierCandidateDism)
if ($task.State -eq 'Running' -and -not $active.Count) {
    if (-not (Get-AtelierPreDismOwner -Report $report -Candidate $candidate)) {
    throw 'Aucun DISM actif ne correspond à cette exécution. Relire le journal pour identifier l''exécution courante avant de l''annuler.'
    }
    Write-Host 'Préparation avant DISM identifiée : arrêt de la tâche de vérification ou de sauvegarde uniquement.'
}

# Suspendre les prochains déclenchements avant d’arrêter la tâche. Aucune écriture en production.
Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
if ($task.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $deadline=(Get-Date).AddSeconds(15)
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        if ((Get-Date) -gt $deadline) { throw 'La tâche ne s''arrête pas. Aucun processus DISM arrête manuellement.' }
        Start-Sleep -Milliseconds 250
    }
}
$held=$null
try {
    # Exclure une autre maintenance ou mise à niveau pendant la récupération du montage.
    $held=[IO.File]::Open((Join-Path $root 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $report.status='cancelled_cleanup_required'
    $report | Add-Member NoteProperty cancelled_at ([DateTime]::UtcNow.ToString('o')) -Force
    $report | Add-Member NoteProperty error 'Préparation annulée par l''opérateur ; copie candidate abandonnée. Image de production non modifiée.' -Force
    Write-AtelierServicingJson $report $reportPath
    foreach ($process in @(Get-AtelierCandidateDism)) {
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$process.ProcessId)
        if ($current -and $current.CreationDate -eq $process.CreationDate -and $current.CommandLine -eq $process.CommandLine) {
            Write-Host ('Arrêt du DISM de la copie candidate uniquement : '+$process.ProcessId)
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
    }
    $deadline=(Get-Date).AddSeconds(15)
    while (@(Get-AtelierCandidateDism).Count) {
        if ((Get-Date) -gt $deadline) { throw 'DISM encore actif ; ne pas relancer la maintenance ni la mise à jour de la console.' }
        Start-Sleep -Milliseconds 250
    }
    if (@(Get-AtelierCandidateMount).Count) {
        Write-Host 'Démontage de la copie candidate avec abandon des changements...'
        Dismount-WindowsImage -Path $mount -Discard -LogPath (Join-Path $run 'cancel-discard.log') -ErrorAction Stop | Out-Null
    }
    if (@(Get-AtelierCandidateMount).Count) { throw 'Montage encore présent ; journaux et copie candidate conservés pour récupération.' }
    if (Test-Path -LiteralPath $candidate) {
        $probe=[IO.File]::Open($candidate,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        $probe.Dispose()
    }
    $report.status='cancelled'
    Write-AtelierServicingJson $report $reportPath
    Write-Host 'Maintenance annulée et montage libéré. Planification en pause.' -ForegroundColor Green
    Write-Host 'Image Windows originale, sauvegardes, cache et journaux conservés. La copie candidate annulée ne doit pas être utilisée.'
} finally { if ($held) { $held.Dispose() } }
