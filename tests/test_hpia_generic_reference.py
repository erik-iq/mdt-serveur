"""Regression from the supplied HP report, with public metadata and no PC identity."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def run_ps(tmp_path,body):
    script=tmp_path/'run.ps1';script.write_text(body.replace('PROJECT',str(ROOT)).replace('WORK',str(tmp_path)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=25)
    assert run.returncode==0,run.stdout+run.stderr
    return json.loads(run.stdout.splitlines()[-1])


def test_analysis_recommendations_are_not_installation_results_and_french_csv_is_read(tmp_path):
    shutil.copy(ROOT/'tests/fixtures/hpia-generic-analysis.json',tmp_path/'report.json')
    (tmp_path/'SoftPaqReport.csv').write_text('Statut,Nom,Cat\u00e9gorie,SoftPaq,AutoInstallable\nNon install\u00e9,Outil HP,Software,sp12345,Faux\nNouvelle version,Pilote HP,Driver,sp23456,Vrai\n',encoding='utf-8-sig')
    result=run_ps(tmp_path,r'''
. 'PROJECT/scripts/HP-ImageAssistant.ps1'
@{packages=@(Read-AtelierHpiaPackages 'WORK');recommendations=@(Get-AtelierHpiaRecommendedSoftpaqs 'WORK');csv=@(Read-AtelierHpiaAutoReport 'WORK')} | ConvertTo-Json -Depth 5 -Compress
''')
    assert result['packages']==[]
    assert len(result['recommendations'])==11
    assert len(result['csv'])==1 and result['csv'][0]['manual'] and result['csv'][0]['name']=='Outil HP'
    assert result['csv'][0]['code'] is None and result['csv'][0]['category']=='Software'


@pytest.mark.parametrize('case',['installed','installed_4104','restart','failure','analysis_only','still_4104'])
def test_generic_reference_keeps_actual_installation_exit_and_never_invents_success(tmp_path,case):
    program=tmp_path/'Program Files';exe=program/'AtelierPXE/Tools/HPImageAssistant/HPImageAssistant.exe'
    exe.parent.mkdir(parents=True);exe.write_bytes(b'fixture binary - never executed')
    data=tmp_path/'data';data.mkdir()
    (data/'ready-tools.json').write_text(json.dumps([{'path':str(exe),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest()}]))
    (data/'personalization.json').write_text('{"deployment":{"hp_repository":true,"id":"12345678-1234-1234-1234-123456789abc"}}')
    (data/'HP-ClientRepository.ps1').write_text("function Get-AtelierHpRepository {param($DataPath,$RequiredSoftpaqs,$OnProgress,[switch]$PrepareOnly);return [pscustomobject]@{status='online';message='Fixture online'}}")
    result=run_ps(tmp_path,r'''
$ErrorActionPreference='Stop'
$env:ProgramFiles='WORK/Program Files'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);return [pscustomobject]@{Manufacturer='HP'}}
function Get-Process {param($Name);return }
function Get-AuthenticodeSignature {param($LiteralPath);return [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=HP Inc.'}}}
. 'PROJECT/scripts/HP-ImageAssistant.ps1'
$script:calls=0
function Invoke-AtelierHpiaProcess {
 param($Executable,$Arguments,$Directory,$ResultPath,$State,$OnProgress,$TimeoutSeconds)
 $script:calls++
 $fixture=Get-Content 'PROJECT/tests/fixtures/hpia-generic-analysis.json' -Raw | ConvertFrom-Json
 if ($Arguments -like '*/Action:List*') {
  $fixture | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Directory 'HPIA.json')
  return 4104
 }
 if ($Arguments -notlike '*/Action:Install*' -or $Arguments -notlike '*/IgnoreGenericOsError*' -or $Arguments -like '*/Force*' -or $Arguments -like '*/AutoReport*') {throw 'Unexpected HPIA command'}
 if ('CASE' -notin @('analysis_only','still_4104')) {
  $fixture.HPIA.HPIAOperation='Analyze Action Install'
  foreach ($item in $fixture.HPIA.Recommendations) { $item.Remediation=[pscustomobject]@{ReturnCode=0;ReturnDescription='Applied'} }
  if ('CASE' -eq 'failure') { $fixture.HPIA.Recommendations[0].Remediation.ReturnCode=1603 }
  if ('CASE' -eq 'restart') { $fixture.HPIA.Recommendations[0].Remediation.ReturnCode=3010 }
 }
 $fixture | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Directory 'HPIA.json')
 if ('CASE' -eq 'failure') {return 3020}
 if ('CASE' -eq 'restart') {return 3010}
 if ('CASE' -in @('still_4104','installed_4104')) {return 4104}
 return 0
}
$first=Invoke-AtelierHpia -DataPath 'WORK/data' -ToolsPath 'WORK/IQ_'
$second=Invoke-AtelierHpia -DataPath 'WORK/data' -ToolsPath 'WORK/IQ_'
@{first=$first;calls=$script:calls;second_exit=$second.exit_code} | ConvertTo-Json -Depth 12 -Compress
'''.replace('CASE',case))
    state=result['first']
    assert result['calls']==2 and state['analysis_exit_code']==4104
    assert state['status']==('completed' if case in {'installed','installed_4104','restart'} else 'needs_attention') and state['generic_os_reference']
    assert state['exit_code']==result['second_exit']==({'failure':3020,'restart':3010,'still_4104':4104,'installed_4104':4104}.get(case,0))
    assert state['reboot_required']==(case=='restart')
    if case in {'analysis_only','still_4104'}:
        assert state['packages']==[] and 'Un ou plusieurs SoftPaq' not in state['message']
        if case=='analysis_only':assert 'aucun resultat' in state['message']
    else:
        assert len(state['packages'])==11 and all(p['code'] is not None for p in state['packages'])
        if case=='installed':assert 'Reference HP generique' in state['message'] and 'Un ou plusieurs SoftPaq' not in state['message']
