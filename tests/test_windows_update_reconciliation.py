"""Une recherche vide ne remplace jamais une preuve d’installation manquante."""
from test_windows_update_install_test import execute, PWSH
import pytest

pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['history','installed','missing','history_failed','history_stale','revision_mismatch','partial','busy','timeout','known_failure','ambiguous_history'])
def test_native_history_or_installed_state_required_for_recovery(tmp_path,case):
    value=execute(tmp_path,r'''
$case='CASE';$script:searched=0;$script:aborted=$false
$testStart=[datetime]::UtcNow.AddMinutes(-2)
$id='7f2b6bcb-5bb6-4b02-9706-2f9d92510804'
$entry=[pscustomobject]@{id=$id;revision=1;title='Intel component';status=$(if($case -eq 'known_failure'){'failed'}else{'installing'});started_utc=$testStart.ToString('o');result_code=$(if($case -eq 'known_failure'){4}else{$null});hresult=$null}
$pass=[pscustomobject]@{status='failed';message='Missing return code';updates=@($entry)}
$searcher=[pscustomobject]@{ServerSelection=0;Online=$true}
$searcher|Add-Member ScriptMethod GetTotalHistoryCount {if($case -in @('history','history_failed','history_stale','revision_mismatch','known_failure','ambiguous_history')){return 1};return 0}
$searcher|Add-Member ScriptMethod QueryHistory {param($start,$count)
 [pscustomobject]@{UpdateIdentity=@{UpdateID=$id;RevisionNumber=$(if($case -eq 'revision_mismatch'){2}else{1})};Operation=1;Date=$(if($case -eq 'history_stale'){$testStart.AddDays(-1)}elseif($case -eq 'ambiguous_history'){[datetime]::SpecifyKind($testStart.AddSeconds(1),[DateTimeKind]::Unspecified)}else{$testStart.AddSeconds(1)});ResultCode=$(if($case -eq 'history_failed'){4}else{2});HResult=$(if($case -eq 'history_failed'){-2145124329}else{0})}
}
$searcher|Add-Member ScriptMethod BeginSearch {param($query,$callback,$state)
 if(-not $callback){throw 'COM callback required'}
 if($query -ne "IsInstalled=1 and UpdateID='$id'"){throw 'Must query exact installed identity'}
 $script:searched++
 $job=[pscustomobject]@{IsCompleted=($case -ne 'timeout')}
 $job|Add-Member ScriptMethod RequestAbort {$script:aborted=$true}
 $job|Add-Member ScriptMethod CleanUp {}
 return $job
}
$searcher|Add-Member ScriptMethod EndSearch {param($job)
 [pscustomobject]@{ResultCode=$(if($case -eq 'partial'){3}else{2});Updates=$(if($case -in @('installed','partial','ambiguous_history')){@([pscustomobject]@{Identity=@{UpdateID=$id;RevisionNumber=1};IsInstalled=$true})}else{@()})}
}
$session=[pscustomobject]@{ClientApplicationID='';Searcher=$searcher}
$session|Add-Member ScriptMethod CreateUpdateSearcher {$this.Searcher}
$session|Add-Member ScriptMethod CreateUpdateInstaller {[pscustomobject]@{IsBusy=($case -eq 'busy')}}
$session|Add-Member ScriptMethod CreateUpdateDownloader {throw 'Verification must never download'}
$proof=Resolve-AtelierUpdatePass -Pass $pass -SessionFactory {$session} -TimeoutSeconds 1 -PollMilliseconds 10
@{proof=$proof;entry=$entry;pass=$pass;searched=$script:searched;aborted=$script:aborted}|ConvertTo-Json -Depth 12 -Compress
'''.replace('CASE',case))
    confirmed=case in ('history','installed','ambiguous_history')
    assert value['proof']['confirmed']==confirmed,value
    assert value['proof']['pending']==(case=='busy')
    if confirmed:
        assert value['entry']['status']=='installed_verified'
        assert value['entry']['verification_source']==('windows_update_history' if case=='history' else 'installed_state')
        assert value['entry']['result_code']==(2 if case=='history' else None)
        assert value['entry']['hresult']==('0x00000000' if case=='history' else None)
    if case in ('history_failed','known_failure'):assert value['entry']['status']=='failed'
    if case in ('history','history_failed','busy','known_failure'):assert value['searched']==0
    if case=='timeout':assert value['aborted']


@pytest.mark.parametrize('case',['confirmed','unconfirmed','busy'])
def test_existing_kit_verification_worker_never_installs_and_requires_proof(tmp_path,case):
    import json
    import os
    import subprocess
    from pathlib import Path
    from test_windows_update_install_test import ROOT
    (tmp_path/'WindowsUpdate-Diagnostic.ps1').write_text('')
    (tmp_path/'WindowsUpdate-InstallTest.ps1').write_text(r'''
function Get-AtelierTestUpdateResumeAction {param($State,$Boot);return 'finished'}
function Resolve-AtelierUpdatePass {param($Pass)
 if($global:case -eq 'confirmed'){$Pass.updates[0].status='installed_verified';$Pass.status='installed_verified'}
 [pscustomobject]@{confirmed=($global:case -eq 'confirmed');pending=($global:case -eq 'busy');message='Proof fixture'}
}
function Invoke-AtelierTestUpdatePass {param([switch]$VerifyOnly)
 if(-not $VerifyOnly){throw 'Read-only recovery must never install'}
 $global:scans++
 [pscustomobject]@{status='verified';remaining=@();message='No update remaining'}
}
''')
    state={'revision':'WU-INSTALL-2','verification_only':True,'status':'reconciling','message':'','updated_utc':None,'boot':'old','reboot_pending':False,'restarts':1,'passes':[{'status':'failed','message':'No result','updates':[{'status':'installing','title':'Intel component','hresult':None}],'excluded':[]}],'active_pass':None,'verification':None,'report_directory':str(tmp_path/'IQReport'),'kit_path':str(tmp_path),'task_name':'FixtureTask'}
    (tmp_path/'state.json').write_text(json.dumps(state))
    worker=str(ROOT/'scripts/Test-WindowsUpdateInstallation.ps1').replace("'","''")
    code=r'''
$ErrorActionPreference='Stop';$global:case='CASE';$global:scans=0;$global:removed=0
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('WORKER',[ref]$tokens,[ref]$errors)
foreach($definition in @($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})) {Invoke-Expression $definition.Extent.Text}
function Get-CimInstance {[pscustomobject]@{LastBootUpTime=[datetime]::UtcNow.AddMinutes(-20)}}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm);$global:removed++}
function Test-UpdateTestRebootPending {return $false}
$block=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Worker'})[0].Clauses[0].Item2.Extent.Text
$workerFile=Join-Path $PSScriptRoot 'worker-body.ps1'
[IO.File]::WriteAllText($workerFile,$block.Substring(1,$block.Length-2),[Text.UTF8Encoding]::new($true))
& $workerFile
@{state=(Read-UpdateTestState $PSScriptRoot);removed=$global:removed;scans=$global:scans;zip=(Test-Path (Join-Path $PSScriptRoot 'IQReport.zip'))}|ConvertTo-Json -Depth 18 -Compress
'''.replace('WORKER',worker).replace('CASE',case)
    script=tmp_path/'worker-test.ps1';script.write_text(code,encoding='utf-8-sig')
    env=dict(os.environ)
    run=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=20,env=env)
    assert run.returncode==0,run.stderr
    value=json.loads(run.stdout)
    assert value['zip']
    assert value['state']['status']=={'confirmed':'completed','unconfirmed':'needs_attention','busy':'running'}[case],value
    assert value['removed']==(0 if case=='busy' else 1)
    assert value['scans']==(0 if case=='busy' else 1)
