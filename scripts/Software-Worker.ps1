#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstallPath)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Software-Sync.ps1')
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$directory=Join-Path $config.data_dir 'software-sync'
$headers=@{Authorization='Bearer ' + (Get-Content (Join-Path $directory 'worker-key') -Encoding UTF8 -Raw).Trim()}
$base='http://127.0.0.1:' + $config.port + '/api/software-sync'
$workerId=[guid]::NewGuid().ToString()
function Invoke-WorkerApi([string]$Path,$Body) {
    $json=$Body | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri ($base + $Path) -Method POST -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 10
}
function Receive-SoftwareChild($Child,$Diagnostics) {
    $receivedErrors=@()
    Receive-Job $Child -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue -ErrorVariable receivedErrors | Out-Null
    foreach ($record in $receivedErrors) {
        $text=Get-AtelierSoftwareErrorText $record @($headers.Authorization,($headers.Authorization -replace '^Bearer ',''))
        if ($text -and $Diagnostics.Count -lt 12 -and -not $Diagnostics.Contains($text)) { $Diagnostics.Add($text) }
    }
}
function Write-SoftwareWorkerLog([string]$Message) {
    $log=Join-Path $directory 'worker.log'
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Remove-Item $log -Force }
    $safe=Get-AtelierSoftwareErrorText $Message @($headers.Authorization,($headers.Authorization -replace '^Bearer ',''))
    Add-Content -LiteralPath $log -Value ((Get-Date -Format o) + ' : ' + $safe) -Encoding UTF8
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
                    # Start-Job sérialise les tableaux ; aucune commande n’est construite depuis une requête web.
                    $diagnostics=New-Object 'Collections.Generic.List[string]'
                    $child=Start-Job -ScriptBlock {
                        param($Root,$Packages,$Bundles,$JobId,$WorkerId)
                        $ErrorActionPreference='Stop'
                        & (Join-Path $Root 'scripts\Sync-Applications.ps1') -InstallPath $Root -Packages $Packages -BundleIds $Bundles -WebJobId $JobId -WorkerId $WorkerId
                    } -ArgumentList $InstallPath,@($job.packages),@($job.bundle_ids),$job.id,$workerId
                    $deadline=(Get-Date).AddHours(4)
                    while ($child.State -in @('Running','NotStarted')) {
                        Invoke-WorkerApi '/worker/heartbeat' @{worker_id=$workerId;state='busy';job_id=$job.id;message='Synchronisation en cours'} | Out-Null
                        Receive-SoftwareChild $child $diagnostics
                        if ((Get-Date) -gt $deadline) { throw 'Délai maximal de synchronisation depasse (4 heures).' }
                        Start-Sleep -Seconds 3
                    }
                    Receive-SoftwareChild $child $diagnostics
                    $resultPath=Join-Path (Join-Path $directory 'job-results') ($job.id + '.json')
                    $result=@{};$status='failed';$message='Échec de la synchronisation.'
                    if (Test-Path -LiteralPath $resultPath) {
                        $result=Get-Content -LiteralPath $resultPath -Encoding UTF8 -Raw | ConvertFrom-Json
                        $failures=@(@($result.applications)+@($result.bundles) | Where-Object { $_.status -eq 'failed' })
                        $successes=@($result.applications | Where-Object { $_.status -ne 'failed' })
                        $status='completed';$message='Logiciels et bundles à jour'
                        if ($failures.Count) {
                            $status=if ($successes.Count) { 'partial' } else { 'failed' }
                            $message='Certains éléments ont échoué. Consulter le détail ; les anciennes versions restent disponibles.'
                        }
                    } else {
                        if ($child.ChildJobs[0].JobStateInfo.Reason) {
                            $text=Get-AtelierSoftwareErrorText $child.ChildJobs[0].JobStateInfo.Reason @($headers.Authorization,($headers.Authorization -replace '^Bearer ',''))
                            if ($text -and -not $diagnostics.Contains($text)) { $diagnostics.Add($text) }
                        }
                        $message='Aucun bilan produit par le processus PowerShell (état : ' + $child.State + ').'
                        if ($diagnostics.Count) { $message=$diagnostics[0] }
                        $result=@{diagnostics=@($diagnostics.ToArray())}
                        Write-SoftwareWorkerLog ('Demandé ' + $job.id + ' : ' + ($diagnostics -join ' | ') + ' ' + $message)
                    }
                    Invoke-WorkerApi ('/jobs/' + $job.id + '/finish') @{worker_id=$workerId;status=$status;message=$message.Substring(0,[Math]::Min(500,$message.Length));results=$result} | Out-Null
                }
            }
        } catch {
            # Ne pas journaliser les en-têtes REST ou les commandes contenant des identifiants.
            $failure=Get-AtelierSoftwareErrorText $_ @($headers.Authorization,($headers.Authorization -replace '^Bearer ',''))
            Write-SoftwareWorkerLog $failure
            if ($child -and $child.State -eq 'Running') { Stop-Job $child -ErrorAction SilentlyContinue }
            if ($job) {
                try { Invoke-WorkerApi ('/jobs/' + $job.id + '/finish') @{worker_id=$workerId;status='failed';message=$failure.Substring(0,[Math]::Min(500,$failure.Length))} | Out-Null }
                catch { throw 'Agent deconnecte. Redémarrage requis pour récupérer la synchronisation.' }
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
