"""Run analysis/cache/install with native HPIA fixtures and the real client cache."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid
import zipfile

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH or os.name=='nt',reason='PowerShell and Linux executable fixture required')


@pytest.mark.parametrize('case',['cached','pending','failed_sync','failed_worker_offline','bad_archive','manual_package','package_restart','install_failure','analysis_network_failure','no_updates','agent_unavailable','cached_worker_offline','package_cache','bad_cache_signature'])
def test_each_hp_is_analyzed_before_cached_or_online_install_and_no_install_is_retried(tmp_path,case):
    data=tmp_path/'data';data.mkdir();identifier=str(uuid.uuid4());snapshot_id=str(uuid.uuid4())
    for name in ['HP-ImageAssistant.ps1','HP-ClientRepository.ps1','HP-Repository.ps1','Unattend.ps1']:
        shutil.copy(ROOT/'scripts'/name,data/name)
    transport=data/'HP-ClientRepository.ps1'
    # Replace transport only; exercise the production queue/poll/extraction logic.
    transport.write_text(transport.read_text().replace('[int]$WaitSeconds=90','[int]$WaitSeconds=0')+r'''
function Receive-AtelierHpArchive {
 param($Config,$Snapshot,$Path,$OnProgress)
 Copy-Item -LiteralPath 'ARCHIVE' -Destination $Path
 Set-Content 'DATA/downloaded' 'yes'
}
'''.replace('ARCHIVE',str(tmp_path/'server.zip')).replace('DATA',str(data)))
    archive=tmp_path/'server.zip'
    with zipfile.ZipFile(archive,'w') as z:
        z.writestr('.repository/cache/offline/platformList.cab','Référence fixture')
        z.writestr('.repository/cache/8AB8_64_11.0.25h2.cab','Référence fixture')
        z.writestr('sp12345.exe','Package fixture - never executed')
        if case in {'package_cache','bad_cache_signature'}:
            z.writestr('sp12345.cva','CVA fixture')
            z.writestr('.repository/cache/atelier-softpaq-cache.json',json.dumps({'schema':1,'mode':'packages_only','platform':'8AB8','os':'win11','os_version':'25H2','softpaqs':['SP12345']}))
        if case=='bad_archive':z.writestr('../escape.exe','Not allowed')
    program=tmp_path/'Program Files'
    tool=program/'AtelierPXE'/'Tools'/'HPImageAssistant'/'HPImageAssistant.exe';tool.parent.mkdir(parents=True)
    tool.write_text('''#!/usr/bin/env python3
import sys,pathlib,json,os
args=sys.argv[1:]
with open(__file__+'.calls','a') as f:f.write(json.dumps(args)+'\\n')
assert '/Silent' in args and '/Noninteractive' not in args and not any(a.lower().startswith('/force') for a in args)
if '/Action:List' in args:
 if 'CASE'=='analysis_network_failure':sys.exit(12)
 report={'HPIA':{'Recommendations':([] if 'CASE'=='no_updates' else [{'SoftPaqID':'SP12345','Name':'Network driver'}]),'InstalledSoftware':[{'SoftPaqID':'SP77777'}]}}
else:
 assert '/Action:Install' in args and '/AutoReport' not in args and '/IgnoreGenericOsError' in args
 offline=[a for a in args if a.startswith('/OfflineMode:')]
 expected='CASE' not in {'pending','failed_sync','failed_worker_offline','bad_archive','agent_unavailable','no_updates','package_cache','bad_cache_signature'}
 assert bool(offline)==expected,(args,expected)
 if offline:
  cache=pathlib.Path(offline[0].split(':',1)[1]);assert (cache/'sp12345.exe').is_file()
  assert (cache/'.repository/cache/offline/platformList.cab').is_file()
 code=1603 if 'CASE'=='install_failure' else 3010 if 'CASE'=='package_restart' else 0
 report={'HPIA':{'Recommendations':[{'SoftPaqID':'SP12345','Name':'Network driver','Remediation':{'ReturnCode':code,'ReturnDescription':'Native fixture'}}]}}
 if 'CASE'=='manual_package':
  target=pathlib.Path(os.environ['ProgramData'])/'HP/HP Image Assistant';target.mkdir(parents=True,exist_ok=True)
  (target/'SoftPaqReport.csv').write_text('SoftPaqID,Name,AutoInstallable\\nSP23456,Manual utility,FALSE\\n')
pathlib.Path('HPIA.json').write_text(json.dumps(report))
if 'CASE'=='install_failure' and '/Action:Install' in args:sys.exit(12)
'''.replace('CASE',case));tool.chmod(0o755)
    (data/'personalization.json').write_text(json.dumps({'deployment':{'id':identifier,'hp_repository':True},'settings':{'winget_packages':['hpia']}}))
    (data/'reporting.json').write_text(json.dumps({'server_url':'https://atelier.test','id':identifier,'token':'private-fixture-token-not-real'}))
    (data/'ready-tools.json').write_text(json.dumps([{'path':str(tool),'sha256':hashlib.sha256(tool.read_bytes()).hexdigest()}]))
    script=r'''
$ErrorActionPreference='Stop'
$env:ProgramFiles='PROGRAM'
$env:ProgramData='ROOT/ProgramData'
function Get-CimInstance {
 param($ClassName,$OperationTimeoutSec)
 if($ClassName -eq 'Win32_BaseBoard'){[pscustomobject]@{Product='8AB8'}}else{[pscustomobject]@{Manufacturer='HP'}}
}
function Get-ItemProperty {param($Path);[pscustomobject]@{DisplayVersion='25H2';CurrentBuildNumber='26200'}}
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status=$(if('CASE' -eq 'bad_cache_signature' -and $LiteralPath -like '*sp12345.exe'){'NotSigned'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=HP Inc.'}}}
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 if($Headers.Authorization -ne 'Bearer private-fixture-token-not-real'){throw 'Wrong reporting credential'}
 $request=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
 if($request.platform -ne '8AB8' -or $request.os -ne 'win11' -or $request.os_version -ne '25H2'){throw 'Wrong repository key'}
 if('CASE' -notin @('analysis_network_failure','no_updates') -and (@($request.required_softpaqs).Count -ne 1 -or $request.required_softpaqs[0] -ne 'SP12345')){throw 'Installed or obsolète packages requested'}
 $status=if('CASE' -in @('pending','agent_unavailable')){'queued'}elseif('CASE' -in @('failed_sync','failed_worker_offline')){'failed'}else{'ready'}
 @{status=$status;worker_available=$(if('CASE' -in @('agent_unavailable','cached_worker_offline','failed_worker_offline')){$false}else{$true});message='CMSL fixture';platform='8AB8';os='win11';os_version='25H2';snapshot=@{id='SNAPSHOT';url='/api/windows/ID/hp-repository/SNAPSHOT.zip';size=SIZE;sha256='HASH'}}
}
. 'DATA/HP-ImageAssistant.ps1'
if('CASE' -eq 'no_updates') {
 # Linux truncates native exit codes to 8 bits; map the fixture's successful
 # empty analysis to the documented Windows HPIA code 256.
 $script:NativeHpiaProcess=${function:Invoke-AtelierHpiaProcess}
 function Invoke-AtelierHpiaProcess {
  param($Executable,$Arguments,$Directory,$ResultPath,$State,$OnProgress,$TimeoutSeconds)
  $code=& $script:NativeHpiaProcess @PSBoundParameters
  if($Arguments -match '/Action:List'){return 256}
  throw 'No install permitted after an up-to-date analysis'
 }
}
$first=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'ROOT/IQ_' -OnProgress {param($Message);Add-Content 'ROOT/progress.log' $Message}
$second=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'ROOT/IQ_'
@{first=$first;second=$second}|ConvertTo-Json -Depth 12|Set-Content 'ROOT/result.json'
'''.replace('PROGRAM',str(program)).replace('ROOT',str(tmp_path)).replace('DATA',str(data)).replace('CASE',case).replace('SNAPSHOT',snapshot_id).replace('ID',identifier).replace('SIZE',str(archive.stat().st_size)).replace('HASH',hashlib.sha256(archive.read_bytes()).hexdigest())
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr+result.stdout
    outcome=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))['first']
    expected_online=case in {'pending','failed_sync','failed_worker_offline','bad_archive','agent_unavailable','no_updates','bad_cache_signature'}
    assert outcome['source']==('online' if expected_online else 'depot_250'),outcome
    assert outcome['status']==('needs_attention' if case in {'manual_package','install_failure'} else 'completed'),outcome
    assert outcome['reboot_required']==(case=='package_restart')
    calls=[json.loads(line) for line in Path(str(tool)+'.calls').read_text().splitlines()]
    assert len(calls)==(1 if case=='no_updates' else 2) and '/Action:List' in calls[0]
    if case!='no_updates':assert '/Action:Install' in calls[1]
    assert (data/'downloaded').exists() == (case not in {'pending','failed_sync','failed_worker_offline','agent_unavailable','no_updates'})
    assert not (tmp_path/'escape.exe').exists()
    if case=='failed_worker_offline':
        assert 'CMSL fixture' in outcome['repository']['message'] and 'Agent CMSL indisponible' not in outcome['repository']['message']
    if case=='manual_package':
        assert any(p.get('manual') for p in outcome['packages'])
        assert list((tmp_path/'IQ_').rglob('SoftPaqReport.csv'))
    if case=='package_cache':
        assert outcome['repository']['status']=='package_cache'
        assert (data/'HP-SoftPaqs'/'sp12345.exe').exists() and (data/'HP-SoftPaqs'/'sp12345.cva').exists()
