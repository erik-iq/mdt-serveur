"""État durable Windows Update, reprises et impossibilité de terminer avant vérification."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['installed','pending_empty','failed','unknown','search_error','interrupted'])
def test_automatic_update_persists_restarts_and_requires_final_search(tmp_path,case):
    shutil.copy(ROOT/'scripts/Client-WindowsUpdate.ps1',tmp_path)
    (tmp_path/'WindowsUpdate-Diagnostic.ps1').write_text('')
    (tmp_path/'WindowsUpdate-InstallTest.ps1').write_text(r'''
function Invoke-AtelierTestUpdatePass {
 param([switch]$VerifyOnly,$OnProgress,$Checkpoint)
 $global:calls++
 if($VerifyOnly){
  if($global:mode -eq 'search_error'){return [pscustomobject]@{status='failed';message='Network fixture'}}
  return [pscustomobject]@{status=$(if($global:mode -eq 'pending_empty' -or $global:boot -eq 'boot2'){'verified'}else{'remaining'});remaining=@();message='Check fixture'}
 }
 $entry=[pscustomobject]@{status='installing';title='Intel driver';result_code=$null}
 $pass=[pscustomobject]@{status='unknown';message='Fixture';updates=@($entry)}
 & $Checkpoint $pass
 if($global:mode -eq 'interrupted'){throw 'Simulated process interruption'}
 if($global:mode -eq 'installed'){$entry.status='installed';$entry.result_code=2;$pass.status='installed'}
 if($global:mode -eq 'failed'){$entry.status='failed';$entry.result_code=4;$pass.status='failed'}
 return $pass
}
''',encoding='utf-8-sig')
    path=tmp_path/'run.ps1'
    path.write_text(r'''
$ErrorActionPreference='Stop'
$global:mode='CASE';$global:boot='boot1';$global:calls=0
. 'DATA/Client-WindowsUpdate.ps1'
function Get-AtelierHpBootIdentity {return $global:boot}
function Write-AtelierVerifiedUtf8File {param($Path,$Content,[switch]$NoBackup);[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))}
function Get-ItemProperty {param($Path);@{DisplayVersion='26H2';CurrentBuildNumber=26300;UBR=9711;EditionID='Professional'}}
function Test-Path {param($Path)
 if($Path -like 'HKLM:*'){return $global:mode -eq 'pending_empty' -and $global:boot -eq 'boot1'}
 return Microsoft.PowerShell.Management\Test-Path $Path
}
$first=Invoke-AtelierAutomaticWindowsUpdate -DataPath 'DATA'
$before=$global:calls
if($global:mode -eq 'interrupted'){
 $v=Get-Content 'DATA/windows-update-result.json' -Raw|ConvertFrom-Json
 $v.status='running';$v|ConvertTo-Json -Depth 18|Set-Content 'DATA/windows-update-result.json'
}
$same=Invoke-AtelierAutomaticWindowsUpdate -DataPath 'DATA'
$sameCalls=$global:calls
$global:boot='boot2'
$final=Invoke-AtelierAutomaticWindowsUpdate -DataPath 'DATA'
@{first=$first;same=$same;final=$final;before=$before;same_calls=$sameCalls;calls=$global:calls}|ConvertTo-Json -Depth 18 -Compress
'''.replace('DATA',str(tmp_path).replace("'","''")).replace('CASE',case),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(path)],capture_output=True,text=True,timeout=15)
    assert run.returncode==0,run.stderr
    value=json.loads(run.stdout)
    first,final=value['first'],value['final']
    if case in ('installed','pending_empty'):
        assert first['status']=='reboot_pending' and final['status']=='completed',value
        assert value['before']==value['same_calls'] and final['restarts']==1
        if case=='installed':assert final['count']==1 and len(final['passes'])==1
    elif case in ('unknown','interrupted'):
        assert final['status']=='installing' and value['before']==value['calls'],value
    elif case=='failed':assert final['status']=='needs_attention'
    else:assert final['status']=='retry_pending' and final['attempts']==3
    assert final['source']=='windows_update'
