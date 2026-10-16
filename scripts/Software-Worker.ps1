#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstallPath)
$ErrorActionPreference='Stop'
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Raw | ConvertFrom-Json
$directory=Join-Path $config.data_dir 'software-sync'
$headers=@{Authorization='Bearer ' + (Get-Content (Join-Path $directory 'worker-key') -Raw).Trim()}
$base='http://127.0.0.1:' + $config.port + '/api/software-sync'
$workerId=[guid]::NewGuid().ToString()
function Invoke-WorkerApi([string]$Path,$Body) {
    $json=$Body | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri ($base + $Path) -Method POST -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 10
}
$mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-SoftwareWorker')
$locked=$false
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { return }
    while ($true) {
        $child=$null;$job=$null
        try {
            $ready=[bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
            $heartbeat=@{worker_id=$workerId;state='not_ready';message='WinGet absent : exécuter Install-WinGet.ps1 dans cette session, puis redémarrer la tâche agent.'}
            if ($ready) { $heartbeat.state='ready';$heartbeat.message='Agent WinGet prêt' }
            Invoke-WorkerApi '/worker/heartbeat' $heartbeat | Out-Null
            if ($ready) {
                $job=(Invoke-WorkerApi '/worker/claim' @{worker_id=$workerId}).job
                if ($job) {
                    # Start-Job serializes arrays; no shell command is assembled from a web request.
                    $child=Start-Job -ScriptBlock {
                        param($Root,$Packages,$Bundles,$JobId,$WorkerId)
                        & (Join-Path $Root 'scripts\Sync-Applications.ps1') -InstallPath $Root -Packages $Packages -BundleIds $Bundles -WebJobId $JobId -WorkerId $WorkerId
                    } -ArgumentList $InstallPath,@($job.packages),@($job.bundle_ids),$job.id,$workerId
                    $deadline=(Get-Date).AddHours(4)
                    while ($child.State -in @('Running','NotStarted')) {
                        Invoke-WorkerApi '/worker/heartbeat' @{worker_id=$workerId;state='busy';job_id=$job.id;message='Synchronisation en cours'} | Out-Null
                        Receive-Job $child -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
                        if ((Get-Date) -gt $deadline) { throw 'Délai maximal de synchronisation dépassé (4 heures).' }
                        Start-Sleep -Seconds 3
                    }
                    Receive-Job $child -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
                    $resultPath=Join-Path (Join-Path $directory 'job-results') ($job.id + '.json')
                    $result=@{};$status='failed';$message='Échec avant la publication des résultats. Vérifier WinGet et les journaux de l agent.'
                    if (Test-Path -LiteralPath $resultPath) {
                        $result=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                        $failures=@(@($result.applications)+@($result.bundles) | Where-Object { $_.status -eq 'failed' })
                        $successes=@($result.applications | Where-Object { $_.status -ne 'failed' })
                        $status='completed';$message='Logiciels et bundles à jour'
                        if ($failures.Count) {
                            $status=if ($successes.Count) { 'partial' } else { 'failed' }
                            $message='Certains éléments ont échoué. Consulter le détail ; les anciennes versions restent disponibles.'
                        }
                    } elseif ($child.ChildJobs[0].JobStateInfo.Reason) {
                        $message=$child.ChildJobs[0].JobStateInfo.Reason.Message
                    }
                    Invoke-WorkerApi ('/jobs/' + $job.id + '/finish') @{worker_id=$workerId;status=$status;message=$message.Substring(0,[Math]::Min(500,$message.Length));results=$result} | Out-Null
                }
            }
        } catch {
            # Do not log REST headers or command lines containing credentials.
            $log=Join-Path $directory 'worker.log'
            if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Remove-Item $log -Force }
            Add-Content -LiteralPath $log -Value ((Get-Date -Format o) + ' : ' + $_.Exception.Message) -Encoding UTF8
            if ($child -and $child.State -eq 'Running') { Stop-Job $child -ErrorAction SilentlyContinue }
            if ($job) {
                try { Invoke-WorkerApi ('/jobs/' + $job.id + '/finish') @{worker_id=$workerId;status='failed';message='Agent interrompu. Vérifier sa connexion et software-sync\worker.log, puis relancer.'} | Out-Null }
                catch { throw 'Agent déconnecté. Redémarrage requis pour récupérer la synchronisation.' }
            }
        } finally {
            if ($child) { Remove-Job $child -Force -ErrorAction SilentlyContinue }
        }
        Start-Sleep -Seconds 3
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose();$headers.Clear()
}
