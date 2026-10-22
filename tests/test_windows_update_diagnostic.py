"""Diagnostics WUA avec objets simulés, aucune installation Windows."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['found','empty','partial','failure','timeout','configured'])
def test_scan_is_read_only_and_distinguishes_empty_failure_and_old_filter(tmp_path,case):
    script=tmp_path/'test.ps1'
    script.write_text("$ErrorActionPreference='Stop'\n. '"+str(ROOT/'scripts/WindowsUpdate-Diagnostic.ps1')+"'\n"+r'''
$case='CASE'
$script:aborted=$false;$script:cleaned=$false;$script:queries=@()
$updates=@(
 [pscustomobject]@{Title='Security KB';Type=1;BrowseOnly=$false;IsDownloaded=$false;KBArticleIDs=@('1234567');Identity=@{UpdateID='security'};Categories=@(@{Name='Security Updates'})},
 [pscustomobject]@{Title='Driver';Type=2;BrowseOnly=$false;IsDownloaded=$false;KBArticleIDs=@();Identity=@{UpdateID='driver'};Categories=@(@{Name='Drivers'})},
 [pscustomobject]@{Title='Optional software';Type=1;BrowseOnly=$true;IsDownloaded=$false;KBArticleIDs=@();Identity=@{UpdateID='optional'};Categories=@()}
)
$job=[pscustomobject]@{IsCompleted=($case -ne 'timeout')}
$job | Add-Member ScriptMethod RequestAbort {$script:aborted=$true}
$job | Add-Member ScriptMethod CleanUp {$script:cleaned=$true}
$searcher=[pscustomobject]@{Online=$false;ServerSelection=0;Job=$job;Items=$updates}
$searcher | Add-Member ScriptMethod BeginSearch {param($criteria,$callback,$state)
 $script:queries+=@($criteria)
 if($case -eq 'failure'){throw [Runtime.InteropServices.COMException]::new('Service disabled',-2147023838)}
 return $this.Job
}
$searcher | Add-Member ScriptMethod EndSearch {param($job)
 if($case -eq 'timeout'){throw 'EndSearch must not be called before completion'}
 return [pscustomobject]@{ResultCode=$(if($case -eq 'partial'){3}else{2});Updates=$(if($case -eq 'empty'){@()}else{$this.Items});Warnings=@()}
}
$session=[pscustomobject]@{ClientApplicationID='';Searcher=$searcher}
$session | Add-Member ScriptMethod CreateUpdateSearcher {$this.Searcher}
$session | Add-Member ScriptMethod CreateUpdateDownloader {throw 'Diagnostic must never download'}
$session | Add-Member ScriptMethod CreateUpdateInstaller {throw 'Diagnostic must never install'}
$result=Invoke-AtelierUpdateScan -Source $(if($case -eq 'configured'){'configured'}else{'windows_update'}) -TimeoutSeconds 1 -PollMilliseconds 10 -SessionFactory {$session}
@{result=$result;server=$searcher.ServerSelection;online=$searcher.Online;aborted=$script:aborted;cleaned=$script:cleaned;queries=$script:queries}|ConvertTo-Json -Depth 10 -Compress
'''.replace('CASE',case),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=10)
    assert run.returncode==0,run.stderr
    value=json.loads(run.stdout);result=value['result']
    assert value['online'] and value['server']==(0 if case=='configured' else 2)
    assert value['queries']==['IsInstalled=0 and IsHidden=0']
    assert result['status']=={'found':'updates_found','empty':'no_updates','partial':'incomplete','failure':'failed','timeout':'timeout','configured':'updates_found'}[case]
    if case in ('found','configured','partial'):
        assert result['count']==3 and result['previous_filter_count']==1
        assert result['updates'][1]['type']==2 and result['updates'][2]['browse_only']
    if case=='failure':assert result['hresult']=='0x80070422'
    if case=='timeout':assert value['aborted'] and not value['cleaned']
    if case not in ('timeout','failure'):assert value['cleaned']
