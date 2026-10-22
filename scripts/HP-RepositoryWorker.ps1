#requires -Version 5.1
#requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$InstallPath)
$ErrorActionPreference='Stop'
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$root=Join-Path $config.data_dir 'hp-repository'
$secret=(Get-Content (Join-Path $root 'worker-key') -Raw -Encoding UTF8).Trim()
$headers=@{Authorization=('Bearer '+$secret)}
$worker=[guid]::NewGuid().ToString()
. (Join-Path $PSScriptRoot 'HP-Repository.ps1')
. (Join-Path $PSScriptRoot 'Windows-ImageServicing.ps1')
$lastServicingStatus=[DateTime]::MinValue
$base='http://127.0.0.1:'+ $config.port +'/api/hp-repository'
function Invoke-HpWorkerApi([string]$Path,$Body) {
    Invoke-RestMethod -Uri ($base+$Path) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 8))) -TimeoutSec 300
}
function Write-HpWorkerLog([string]$Message) {
    $path=Join-Path $root 'worker.log'
    if ((Test-Path $path) -and (Get-Item $path).Length -gt 2MB) { Move-Item $path ($path+'.previous') -Force }
    $safe=$Message.Replace($secret,'[REDACTED]')
    Add-Content -LiteralPath $path -Value ([DateTime]::UtcNow.ToString('o')+' '+$safe) -Encoding UTF8
}
$mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-HpRepository')
$owned=$false
try {
    try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    if (-not $owned) { return }
    while ($true) {
        $child=$null;$job=$null
        try {
            if (([DateTime]::UtcNow-$lastServicingStatus).TotalSeconds -ge 30) {
                try { Publish-AtelierServicingStatus -DataRoot $config.data_dir } catch { Write-HpWorkerLog ('Lecture du suivi WIM : '+$_.Exception.Message) }
                $lastServicingStatus=[DateTime]::UtcNow
            }
            Import-Module HPCMSL -MinimumVersion '1.9.0' -ErrorAction Stop
            Invoke-HpWorkerApi '/worker/heartbeat' @{worker_id=$worker;state='ready';message='Agent CMSL pret'} | Out-Null
            $job=(Invoke-HpWorkerApi '/worker/claim' @{worker_id=$worker;state='ready'}).job
            if ($job) {
                $child=Start-Job -ScriptBlock {
                    param($Library,$DataRoot,$Request)
                    $ErrorActionPreference='Stop'
                    Import-Module HPCMSL -MinimumVersion '1.9.0' -ErrorAction Stop
                    . $Library
                    Sync-AtelierHpRepository -DataRoot $DataRoot -Job $Request
                } -ArgumentList (Join-Path $PSScriptRoot 'HP-Repository.ps1'),$config.data_dir,$job
                $clock=[Diagnostics.Stopwatch]::StartNew()
                while ($child.State -in @('Running','NotStarted')) {
                    if (([DateTime]::UtcNow-$lastServicingStatus).TotalSeconds -ge 30) {
                        try { Publish-AtelierServicingStatus -DataRoot $config.data_dir } catch { Write-HpWorkerLog ('Lecture du suivi WIM : '+$_.Exception.Message) }
                        $lastServicingStatus=[DateTime]::UtcNow
                    }
                    if ((Get-AtelierHpFreeSpace $root) -lt 2GB) { throw 'Synchronisation CMSL arretee : moins de 2 Go libres sur le serveur.' }
                    Invoke-HpWorkerApi '/worker/heartbeat' @{worker_id=$worker;state='busy';message=('Preparation des pilotes HP '+$job.platform+' / '+$job.os_version)} | Out-Null
                    if ($clock.Elapsed.TotalHours -ge 4) { throw 'Synchronisation CMSL interrompue apres quatre heures ; aucune archive publiee.' }
                    Start-Sleep -Seconds 5
                }
                $result=Receive-Job $child -ErrorAction Stop
                if ($child.State -ne 'Completed' -or -not $result.id) { throw 'CMSL n a pas produit de depot complet.' }
                Invoke-HpWorkerApi ('/worker/jobs/'+$job.id+'/finish') @{worker_id=$worker;success=$true;state='ready';message='Pilotes HP synchronises et conserves sur le serveur'} | Out-Null
            }
        } catch {
            $message=$_.Exception.Message.Replace($secret,'[REDACTED]');Write-HpWorkerLog $message
            Write-HpWorkerLog ([string]$_.InvocationInfo.PositionMessage)
            Write-HpWorkerLog ([string]$_.ScriptStackTrace)
            if ($child -and $child.State -in @('Running','NotStarted')) { Stop-Job $child -ErrorAction SilentlyContinue }
            if ($job) {
                try {
                    $partial=Join-Path $root ('snapshots\'+[guid]::Parse([string]$job.id).ToString()+'.zip.partial')
                    if (Test-Path $partial) { Assert-AtelierHpTree (Split-Path $partial -Parent);Remove-Item -LiteralPath $partial -Force }
                } catch { Write-HpWorkerLog 'Archive HP incomplete conservee ; aucun depot publie remplace.' }
            }
            try {
                if ($job) { Invoke-HpWorkerApi ('/worker/jobs/'+$job.id+'/finish') @{worker_id=$worker;success=$false;state='ready';message=$message.Substring(0,[math]::Min(500,$message.Length))} | Out-Null }
                Invoke-HpWorkerApi '/worker/heartbeat' @{worker_id=$worker;state='not_ready';message=$message.Substring(0,[math]::Min(500,$message.Length))} | Out-Null
            } catch { Write-HpWorkerLog 'Console HP temporairement inaccessible.' }
        } finally { if ($child) { Remove-Job $child -Force -ErrorAction SilentlyContinue } }
        Start-Sleep -Seconds 10
    }
} finally { if ($owned) { $mutex.ReleaseMutex() };$mutex.Dispose();$headers.Clear();$secret=$null }
