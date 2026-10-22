#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$StateRoot=(Join-Path $env:ProgramData 'AtelierPXE-HpiaTest'),[string]$ToolsPath='C:\IQ_',[switch]$Run,[string]$RunId)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$taskName='AtelierPXE-HpiaTest'
function Assert-HpiaTestPath([string]$Path) {
    $item=[IO.Path]::GetFullPath($Path)
    while ($item) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Chemin lie refuse pour le test HP.' }
        $parent=Split-Path $item -Parent
        if ($parent -eq $item) { break };$item=$parent
    }
}
Assert-HpiaTestPath $StateRoot;Assert-HpiaTestPath $ToolsPath
if ([string](Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15).Manufacturer -notmatch '(?i)^(HP|Hewlett[ -]Packard)(\b|\s)') { throw 'Cet outil doit être lancé sur le PC HP, pas sur le serveur PXE.' }
foreach ($name in @('AtelierPXE-Preparation','AtelierPXE-Maintenance')) {
    if ((Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).State -eq 'Running') { throw 'Attendre la fin de la préparation Windows avant le test HP.' }
}
if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)^(HPImageAssistant|HpFirmwareUpdRec.*|HPBIOSUPDREC.*|HPBIOSUpdate.*)$' }).Count) { throw 'HPIA ou une mise à jour BIOS fonctionne déjà. Aucun second traitement lance.' }
$runner=Join-Path $StateRoot 'Runner\Test-HPIA.ps1'
if ($StateRoot.Contains('"') -or $ToolsPath.Contains('"')) { throw 'Chemin de test HP invalide.' }
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and (@($task.Actions).Count -ne 1 -or $task.Actions[0].Arguments -notlike ('*"'+$runner+'"*'))) { throw 'La tâche de test existante ne correspond pas a cet outil.' }
if (-not $Run) {
    if ($task -and $task.State -eq 'Running') { throw 'Le test HP est déjà en cours.' }
    $active=Join-Path $StateRoot 'active.json'
    if ($task -and (Test-Path -LiteralPath $active)) {
        $old=Get-Content -LiteralPath $active -Encoding UTF8 -Raw | ConvertFrom-Json
        $oldId=[guid]::Parse([string]$old.run_id).ToString()
        $oldResult=Join-Path $StateRoot ('Runs\'+$oldId+'\hpia-result.json')
        if (-not (Test-Path -LiteralPath $oldResult)) { throw 'Un test HP est déjà en attente. Consulter AtelierPXE-HpiaTest dans le Planificateur.' }
        $previous=Get-Content -LiteralPath $oldResult -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($previous.status -in @('running','retry_pending','reboot_pending')) { throw 'Le test HP attend une reprise après redémarrage. Ne pas créer une seconde installation.' }
    }
    foreach ($name in @('Test-HPIA.ps1','HP-ImageAssistant.ps1','Unattend.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw ('Outil incomplet : '+$name) }
    }
    New-Item -ItemType Directory -Path (Join-Path $StateRoot 'Runner') -Force | Out-Null
    & icacls.exe $StateRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Impossible de protéger le traitement HP.' }
    foreach ($name in @('Test-HPIA.ps1','HP-ImageAssistant.ps1','Unattend.ps1')) {
        $source=Join-Path $PSScriptRoot $name;$target=Join-Path (Join-Path $StateRoot 'Runner') $name
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)) { Copy-Item -LiteralPath $source -Destination $target -Force }
        Unblock-File -LiteralPath $target
    }
    $RunId=[guid]::NewGuid().ToString()
    $data=Join-Path $StateRoot ('Runs\'+$RunId)
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    . (Join-Path $StateRoot 'Runner\Unattend.ps1')
    $exe=Join-Path $env:ProgramFiles 'AtelierPXE\Tools\HPImageAssistant\HPImageAssistant.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'HP Image Assistant manque. Le test exige son installation vérifiée par Atelier.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $exe
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(HP Inc\.|Hewlett-Packard)') { throw 'Signature de HP Image Assistant invalide.' }
    $tools=@(@{path=$exe;sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()})
    Write-AtelierVerifiedUtf8File -Path (Join-Path $data 'ready-tools.json') -Content (ConvertTo-Json -InputObject $tools -Depth 5) -NoBackup | Out-Null
    # Ce test isolé utilise volontairement HP en ligne, sans réutiliser de jeton de déploiement,
    # d’ancien résultat ni de WIM, et sans les modifier.
    Write-AtelierVerifiedUtf8File -Path (Join-Path $data 'personalization.json') -Content '{"deployment":{"allow_bios_restart":true,"hp_repository":false}}' -NoBackup | Out-Null
    Write-AtelierVerifiedUtf8File -Path $active -Content (@{run_id=$RunId}|ConvertTo-Json) -NoBackup | Out-Null
    $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'+$runner+'" -Run -RunId '+$RunId+' -StateRoot "'+$StateRoot+'" -ToolsPath "'+$ToolsPath+'"'
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments -WorkingDirectory (Split-Path $runner -Parent)
    $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Host 'Test silencieux lance sous SYSTEM, avec reprise après un redémarrage BIOS.'
    Write-Host ('Suivi et archive : '+(Join-Path $ToolsPath ('Rapports\HPImageAssistant\Tests\'+$RunId)))
    Write-Host 'Cette fenêtre peut être fermee ; la tâche continue en arrière-plan.'
    return
}
$RunId=[guid]::Parse($RunId).ToString()
$data=Join-Path $StateRoot ('Runs\'+$RunId)
Assert-HpiaTestPath $data
if (-not (Test-Path -LiteralPath (Join-Path $data 'personalization.json') -PathType Leaf)) { throw 'État de test HP absent.' }
$reports=Join-Path $ToolsPath ('Rapports\HPImageAssistant\Tests\'+$RunId)
Assert-HpiaTestPath $reports
$mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-Maintenance')
$owned=$false;$transcribing=$false
try {
    try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    if (-not $owned) { throw 'Un autre traitement Atelier est actif ; test HP reporté.' }
    New-Item -ItemType Directory -Path $reports -Force | Out-Null
    Start-Transcript -LiteralPath (Join-Path $reports ('test-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.log')) -Append | Out-Null
    $transcribing=$true
    . (Join-Path $PSScriptRoot 'HP-ImageAssistant.ps1')
    Write-Host 'Test du moteur Atelier : tous les SoftPaq recommandés et automatisables, avertissement de version ignorée, source HP Internet.'
    $result=Invoke-AtelierHpia -DataPath $data -ToolsPath $ToolsPath -ReportRoot $reports -OnProgress {param($Message);Write-Host $Message}
    Copy-Item -LiteralPath (Join-Path $data 'hpia-result.json') -Destination (Join-Path $reports 'hpia-result.json') -Force
    Write-Host $result.message
    if ($result.reboot_required -and $result.status -ne 'reboot_pending') { Write-Host 'Redémarrage manuel nécessaire. Après redémarrage, relancer le test pour vérifier les pilotes restants.' }
    Stop-Transcript | Out-Null;$transcribing=$false
    try { Compress-Archive -Path (Join-Path $reports '*') -DestinationPath ($reports+'.zip') -Force -ErrorAction Stop }
    catch { Write-Warning ('Archive du test non créée : '+$_.Exception.Message+'. Les rapports restent dans '+$reports) }
    if ($result.status -eq 'reboot_pending') { Request-AtelierHpBiosRestart -DataPath $data }
    elseif ($result.status -notin @('running','retry_pending')) {
        if ($task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
    }
} finally {
    if ($transcribing) { Stop-Transcript | Out-Null }
    if ($owned) { $mutex.ReleaseMutex() };$mutex.Dispose()
}
