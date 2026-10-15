"""Run update decision logic with fake COM objects, never install updates here."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH, reason='PowerShell required')


def execute(tmp_path, code):
    script=tmp_path/'verify.ps1'
    script.write_text("$ErrorActionPreference='Stop'\n. '"+str(ROOT/'scripts'/'Updates.ps1').replace("'","''")+"'\n"+code,encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(script)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0, result.stderr
    return result.stdout.strip()


@pytest.mark.parametrize(('case','expected'), [
    ('empty','up_to_date'), ('success','installed'), ('reboot','installed'), ('pending_reboot','reboot_required'),
    ('search_failed','failed'), ('download_failed','failed'), ('install_failed','failed'),
    ('individual_failed','failed'), ('interactive','failed')])
def test_update_results_reboot_and_partial_failures(tmp_path,case,expected):
    code=r'''
$case='CASE'
$update=[pscustomobject]@{Title='Test cumulative update';EulaAccepted=$false;InstallationBehavior=[pscustomobject]@{CanRequestUserInput=($case -eq 'interactive')}}
$update | Add-Member ScriptMethod AcceptEula { $this.EulaAccepted=$true }
$search=[pscustomobject]@{ResultCode=$(if($case -eq 'search_failed'){3}else{2});Updates=$(if($case -eq 'empty'){@()}else{@($update)})}
$searcher=[pscustomobject]@{Data=$search}
$searcher | Add-Member ScriptMethod Search { param($query) if($query -notmatch "BrowseOnly=0" -or $query -notmatch "Type='Software'"){throw 'Wrong update policy'}; return $this.Data }
$downloadResult=[pscustomobject]@{ResultCode=$(if($case -eq 'download_failed'){3}else{2})}
$downloader=[pscustomobject]@{Updates=$null;Data=$downloadResult}
$downloader | Add-Member ScriptMethod Download { return $this.Data }
$installResult=[pscustomobject]@{ResultCode=$(if($case -eq 'install_failed'){3}else{2});RebootRequired=($case -eq 'reboot');Individual=$(if($case -eq 'individual_failed'){4}else{2})}
$installResult | Add-Member ScriptMethod GetUpdateResult { param($index) return [pscustomobject]@{ResultCode=$this.Individual} }
$installer=[pscustomobject]@{Updates=$null;AllowSourcePrompts=$true;ForceQuiet=$false;Data=$installResult;RebootRequiredBeforeInstallation=($case -eq 'pending_reboot')}
$installer | Add-Member ScriptMethod Install { return $this.Data }
$session=[pscustomobject]@{ClientApplicationID='';Searcher=$searcher;Downloader=$downloader;Installer=$installer}
$session | Add-Member ScriptMethod CreateUpdateSearcher { return $this.Searcher }
$session | Add-Member ScriptMethod CreateUpdateDownloader { return $this.Downloader }
$session | Add-Member ScriptMethod CreateUpdateInstaller { return $this.Installer }
try {
    $result=Invoke-AtelierWindowsUpdates -SessionFactory { $session } -CollectionFactory { ,(New-Object Collections.ArrayList) }
    $result | ConvertTo-Json -Depth 5 -Compress
} catch { @{status='failed'} | ConvertTo-Json -Compress }
'''.replace('CASE',case)
    result=json.loads(execute(tmp_path,code))
    assert result['status']==expected
    if expected!='failed':
        assert result['reboot_required']==(case in {'reboot','pending_reboot'})
        assert result['count']==(0 if case in {'empty','pending_reboot'} else 1)


@pytest.mark.parametrize('return_code',[0,1])
def test_store_reports_request_not_completion(tmp_path,return_code):
    code='''
function Get-CimInstance { param($Namespace,$ClassName) [pscustomobject]@{id='store'} }
function Invoke-CimMethod { param($InputObject,$MethodName) [pscustomobject]@{ReturnValue=RETURN_CODE} }
try { Request-AtelierStoreUpdates | ConvertTo-Json -Compress } catch { @{status='failed'} | ConvertTo-Json -Compress }
'''.replace('RETURN_CODE',str(return_code))
    result=json.loads(execute(tmp_path,code))
    assert result['status']==('requested' if return_code==0 else 'failed')
    if return_code==0:
        assert result['completion_verified'] is False


def test_async_jobs_emit_real_phases_and_release_resources(tmp_path):
    result=json.loads(execute(tmp_path,r'''
$script:phases=New-Object Collections.ArrayList
$script:cleaned=0
function New-Job {
    $job=[pscustomobject]@{ticks=0}
    $job | Add-Member ScriptProperty IsCompleted { $this.ticks++; return $this.ticks -gt 1 }
    $job | Add-Member ScriptMethod GetProgress { [pscustomobject]@{PercentComplete=47;CurrentUpdateIndex=0} }
    $job | Add-Member ScriptMethod CleanUp { $script:cleaned++ }
    return $job
}
$update=[pscustomobject]@{Title='KB123 cumulative';EulaAccepted=$true;InstallationBehavior=[pscustomobject]@{CanRequestUserInput=$false}}
$searcher=[pscustomobject]@{Updates=@($update)}
$searcher | Add-Member ScriptMethod BeginSearch { param($criteria,$callback,$state);New-Job }
$searcher | Add-Member ScriptMethod EndSearch { param($job);[pscustomobject]@{ResultCode=2;Updates=$this.Updates} }
$downloader=[pscustomobject]@{Updates=$null}
$downloader | Add-Member ScriptMethod BeginDownload { param($progress,$callback,$state);New-Job }
$downloader | Add-Member ScriptMethod EndDownload { param($job);[pscustomobject]@{ResultCode=2} }
$installer=[pscustomobject]@{Updates=$null;AllowSourcePrompts=$true;ForceQuiet=$false;RebootRequiredBeforeInstallation=$false}
$installer | Add-Member ScriptMethod BeginInstall { param($progress,$callback,$state);New-Job }
$installer | Add-Member ScriptMethod EndInstall {
    param($job)
    $result=[pscustomobject]@{ResultCode=2;RebootRequired=$false}
    $result | Add-Member ScriptMethod GetUpdateResult { param($index);[pscustomobject]@{ResultCode=2} }
    return $result
}
$session=[pscustomobject]@{ClientApplicationID='';Searcher=$searcher;Downloader=$downloader;Installer=$installer}
$session | Add-Member ScriptMethod CreateUpdateSearcher { $this.Searcher }
$session | Add-Member ScriptMethod CreateUpdateDownloader { $this.Downloader }
$session | Add-Member ScriptMethod CreateUpdateInstaller { $this.Installer }
$result=Invoke-AtelierWindowsUpdates -PollMilliseconds 1 -SessionFactory { $session } -CollectionFactory { ,(New-Object Collections.ArrayList) } -OnProgress { param($p);$script:phases.Add($p) | Out-Null }
@{result=$result;phases=@($script:phases);cleaned=$script:cleaned} | ConvertTo-Json -Depth 8 -Compress
'''))
    assert result['result']['status']=='installed'
    assert result['cleaned']==3
    assert {p['phase'] for p in result['phases']} == {'search','download','install','installed'}
    assert any(p['percent']==47 and p['title']=='KB123 cumulative' for p in result['phases'])


@pytest.mark.parametrize(('serial','mode','name'),[
    ('5CD123AB78','digits','LE-T15-2378'),('5CD123AB78','characters','LE-T15-AB78'),
    (' 5cd123ab78 ','digits','LE-T15-2378'),('To Be Filled By O.E.M.','digits',None),
    ('AB12','digits',None),('','digits',None),('12345678','digits','LE-T15-5678')])
def test_serial_naming(tmp_path,serial,mode,name):
    code=". '"+str(ROOT/'scripts'/'Naming.ps1').replace("'","''")+"'\n"
    code+="try { @{name=(Get-AtelierComputerName -SerialNumber '"+serial+"' -SuffixMode '"+mode+"')} | ConvertTo-Json -Compress } catch { @{name=$null} | ConvertTo-Json -Compress }"
    assert json.loads(execute(tmp_path,code))['name']==name
