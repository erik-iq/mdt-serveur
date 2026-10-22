"""Installation WUA simulée : rappels valides, résultats individuels et reprise."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def execute(tmp_path,code):
    path=tmp_path/'test.ps1'
    path.write_text("$ErrorActionPreference='Stop'\n. '"+str(ROOT/'scripts/WindowsUpdate-Diagnostic.ps1')+"'\n. '"+str(ROOT/'scripts/WindowsUpdate-InstallTest.ps1')+"'\n"+code,encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(path)],capture_output=True,text=True,timeout=15)
    assert run.returncode==0,run.stderr
    return json.loads(run.stdout)


@pytest.mark.parametrize('case',['success','empty','search_partial','download_failed','install_partial','reboot','pre_reboot','verify','timeout','upgrade','can_request_input'])
def test_real_result_controls_next_action_and_no_install_before_checkpoint(tmp_path,case):
    value=execute(tmp_path,r'''
$case='CASE'
$script:downloaded=0;$script:installed=0;$script:checkpoint=$null;$script:callbacks=0
function Check-Callback($a,$b) {
 if(-not $a -or -not $b){throw 'Missing COM callback'}
 $a.Invoke($null,$null);$b.Invoke($null,$null);$script:callbacks++
}
function New-TestJob {
 $job=[pscustomobject]@{IsCompleted=$true}
 $job|Add-Member ScriptMethod CleanUp {}
 return $job
}
$update=[pscustomobject]@{Title='Test software';Type=1;IsDownloaded=$false;EulaAccepted=$true;Identity=@{UpdateID='test';RevisionNumber=1};InstallationBehavior=@{CanRequestUserInput=($case -eq 'can_request_input')};Categories=@()}
if($case -eq 'upgrade'){$update.Categories=@(@{CategoryID='3689bdc8-b205-4af4-8d4a-a63924c5e9d5';Name='Upgrades'})}
$searcher=[pscustomobject]@{Online=$false;ServerSelection=0;Update=$update}
$searcher|Add-Member ScriptMethod BeginSearch {param($query,$callback,$state)
 if(-not $callback){throw 'Missing search callback'};$callback.Invoke($null,$null);New-TestJob
}
$searcher|Add-Member ScriptMethod EndSearch {param($job)
 [pscustomobject]@{ResultCode=$(if($case -eq 'search_partial'){3}else{2});Updates=$(if($case -eq 'empty'){@()}else{@($this.Update)})}
}
$downloader=[pscustomobject]@{Updates=$null}
$downloader|Add-Member ScriptMethod BeginDownload {param($progress,$completed,$state);Check-Callback $progress $completed;$script:downloaded++;New-TestJob}
$downloader|Add-Member ScriptMethod EndDownload {param($job)
 $r=[pscustomobject]@{ResultCode=2}
 $r|Add-Member ScriptMethod GetUpdateResult {param($i);[pscustomobject]@{ResultCode=$(if($case -eq 'download_failed'){4}else{2});HResult=-2145124329}}
 return $r
}
$installer=[pscustomobject]@{IsBusy=$false;RebootRequiredBeforeInstallation=($case -eq 'pre_reboot');Updates=$null;AllowSourcePrompts=$true;ForceQuiet=$false}
$installer|Add-Member ScriptMethod BeginInstall {param($progress,$completed,$state)
 if(-not $this.ForceQuiet -or $this.AllowSourcePrompts){throw 'Silent mode required'}
 if($script:checkpoint.updates[-1].status -ne 'installing'){throw 'Missing durable checkpoint'}
 Check-Callback $progress $completed;$script:installed++
 $job=New-TestJob
 if($case -eq 'timeout'){$job.IsCompleted=$false}
 return $job
}
$installer|Add-Member ScriptMethod EndInstall {param($job)
 $r=[pscustomobject]@{ResultCode=2;RebootRequired=($case -eq 'reboot')}
 $r|Add-Member ScriptMethod GetUpdateResult {param($i);[pscustomobject]@{ResultCode=$(if($case -eq 'install_partial'){4}else{2});HResult=$(if($case -eq 'install_partial'){-2145124329}else{0});RebootRequired=($case -eq 'reboot')}}
 return $r
}
$session=[pscustomobject]@{ClientApplicationID='';Searcher=$searcher;Downloader=$downloader;Installer=$installer}
$session|Add-Member ScriptMethod CreateUpdateSearcher {$this.Searcher}
$session|Add-Member ScriptMethod CreateUpdateDownloader {$this.Downloader}
$session|Add-Member ScriptMethod CreateUpdateInstaller {$this.Installer}
$result=Invoke-AtelierTestUpdatePass -SessionFactory {$session} -CollectionFactory {,(New-Object Collections.ArrayList)} -PollMilliseconds 10 -OperationTimeoutSeconds 1 -VerifyOnly:($case -eq 'verify') -Checkpoint {param($v);$script:checkpoint=$v}
@{result=$result;downloaded=$script:downloaded;installed=$script:installed;callbacks=$script:callbacks}|ConvertTo-Json -Depth 12 -Compress
'''.replace('CASE',case))
    result=value['result']
    assert result['status']=={'success':'installed','empty':'verified','search_partial':'failed','download_failed':'failed','install_partial':'failed','reboot':'reboot_required','pre_reboot':'reboot_required','verify':'remaining','timeout':'unknown','upgrade':'verified','can_request_input':'installed'}[case],result
    if case in ('empty','search_partial','pre_reboot','verify','upgrade'):assert value['installed']==value['downloaded']==0
    if case=='download_failed':assert value['downloaded']==1 and value['installed']==0
    if case in ('success','reboot','install_partial','timeout'):assert value['installed']==1 and value['callbacks']==2
    if case in ('success','can_request_input'):assert result['updates'][0]['status']=='installed' and result['updates'][0]['hresult']=='0x00000000'
    if case=='install_partial':assert result['updates'][0]['status']=='failed'
    if case=='timeout':assert result['updates'][0]['status']=='installing'
    if case=='upgrade':assert len(result['excluded'])==1


@pytest.mark.parametrize(('status','active','boot','expected'),[
    ('new',False,'old','continue'),('restart_pending',False,'old','wait_for_restart'),
    ('restart_pending',False,'new','continue'),('running',True,'new','verify_interrupted'),
    ('completed',False,'new','finished'),('needs_attention',False,'new','finished')])
def test_resume_requires_real_boot_and_never_replays_uncertain_install(tmp_path,status,active,boot,expected):
    code="$state=[pscustomobject]@{status='STATUS';boot='old';active_pass=ACTIVE}\n@{action=(Get-AtelierTestUpdateResumeAction $state 'BOOT')}|ConvertTo-Json -Compress"
    value=execute(tmp_path,code.replace('STATUS',status).replace('ACTIVE','@{updates=@()}' if active else '$null').replace('BOOT',boot))
    assert value['action']==expected


def test_worker_never_finishes_green_before_pending_reboot_and_state_has_backup(tmp_path):
    worker=str(ROOT/'scripts/Test-WindowsUpdateInstallation.ps1').replace("'","''")
    folder=str(tmp_path).replace("'","''")
    code=r'''
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('WORKER',[ref]$tokens,[ref]$errors)
foreach($name in @('Save-UpdateTestState','Read-UpdateTestState','Test-UpdateTestRebootPending','Set-UpdateTestVerifiedStatus')) {
 $definition=$ast.Find({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 Invoke-Expression $definition.Extent.Text
}
$script:pending=$true
function Test-Path {param($Path)
 if($Path -like 'HKLM:*'){return $script:pending}
 return Microsoft.PowerShell.Management\Test-Path $Path
}
$state=[pscustomobject]@{status='new';updated_utc=$null;reboot_pending=$false;restarts=0;message=''}
Save-UpdateTestState $state 'FOLDER'
Set-UpdateTestVerifiedStatus $state
$first=$state.status;$restarts=$state.restarts
Save-UpdateTestState $state 'FOLDER'
[IO.File]::WriteAllText((Join-Path 'FOLDER' 'state.json'),'incomplete JSON')
$backup=Read-UpdateTestState 'FOLDER'
$script:pending=$false;Set-UpdateTestVerifiedStatus $state;$finished=$state.status
$script:pending=$true;$state.restarts=6;Set-UpdateTestVerifiedStatus $state
@{first=$first;restarts=$restarts;backup=$backup.status;finished=$finished;limit=$state.status}|ConvertTo-Json -Compress
'''.replace('WORKER',worker).replace('FOLDER',folder)
    value=execute(tmp_path,code)
    assert value=={'first':'restart_pending','restarts':1,'backup':'new','finished':'completed','limit':'needs_attention'}
