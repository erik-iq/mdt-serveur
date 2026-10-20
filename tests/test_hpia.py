"""HPIA trust checks, CLI, durable results, native result codes and report parsing."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from datetime import datetime

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def ps(path):return str(path).replace("'","''")


@pytest.mark.skipif(os.name=='nt',reason='Linux executable fixture')
@pytest.mark.parametrize('case',['success','powershell51_tools','package_restart','package_failure','bad_hash','bad_signature','non_hp','missing','interrupted','timeout'])
def test_background_softpaq_selection_and_idempotent_result(tmp_path,case):
    data=tmp_path/'data';data.mkdir()
    program=tmp_path/'Program Files';tool=program/'AtelierPXE'/'Tools'/'hp'/'HPImageAssistant.exe';tool.parent.mkdir(parents=True)
    native_code=3010 if case=='package_restart' else 12 if case=='package_failure' else 0
    tool.write_text('''#!/usr/bin/env python3
import sys,pathlib,json,time
pathlib.Path(__file__+'.calls').write_text(json.dumps(sys.argv[1:]))
time.sleep(WAIT_SECONDS)
pathlib.Path('HPIA.json').write_text(json.dumps({'HPIA':{'Recommendations':[{'Name':'Pilote HP test','SoftPaqID':'SP12345','Remediation':{'ReturnCode':CODE,'ReturnDescription':'SoftPaq fixture'}}]}}))
'''.replace('CODE',str(native_code)).replace('WAIT_SECONDS','7' if case=='timeout' else '0'));tool.chmod(0o755)
    if case!='missing':
        tools=[{'path':str(tool),'sha256':'wrong' if case=='bad_hash' else hashlib.sha256(tool.read_bytes()).hexdigest()}]
        if case=='powershell51_tools':tools.insert(0,{'path':str(program/'another-tool.exe'),'sha256':'unused'})
        (data/'ready-tools.json').write_text(json.dumps(tools))
    if case=='interrupted':(data/'hpia-result.json').write_text('{"status":"running","process_id":12345}')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
$env:ProgramFiles='PROGRAM'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);[pscustomobject]@{Manufacturer='MANUFACTURER'}}
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='PUBLISHER'}}}
. 'LIBRARY'
. 'TIMINGS'
$first=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'TOOLS' -TimeoutSeconds TIMEOUT
if ('CASE' -eq 'timeout') {
    $active=Get-Process -Id $first.process_id -ErrorAction Stop
    if ($active.HasExited) { throw 'The native process must not be killed at the timeout' }
    $active.WaitForExit()
}
$second=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'TOOLS'
@{first=$first;second=$second}|ConvertTo-Json -Depth 6|Set-Content 'RESULT' -Encoding UTF8
""".replace('PROGRAM',ps(program)).replace('MANUFACTURER','Dell' if case=='non_hp' else 'HP')
    .replace('PUBLISHER','CN=Other publisher' if case=='bad_signature' else 'CN=HP Inc., O=HP Inc.')
    .replace('LIBRARY',ps(ROOT/'scripts'/'HP-ImageAssistant.ps1')).replace('TIMINGS',ps(ROOT/'scripts'/'Timings.ps1'))
    .replace('DATA',ps(data)).replace('TOOLS',ps(tmp_path/'IQ tools')).replace('RESULT',ps(tmp_path/'result.json'))
    .replace('TIMEOUT','1' if case=='timeout' else '30').replace('CASE',case),encoding='utf-8-sig')
    if case=='powershell51_tools':
        wrapper.write_text(r"""function ConvertFrom-Json {
 [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)][string]$InputObject)
 process { Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate }
}
"""+wrapper.read_text(encoding='utf-8-sig'),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    result=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))
    # PowerShell 7 may parse JSON dates as DateTime and omit a trailing zero.
    first_time=datetime.fromisoformat(result['first'].pop('timestamp'))
    second_time=datetime.fromisoformat(result['second'].pop('timestamp'))
    assert first_time==second_time and result['first']==result['second']
    status='skipped' if case=='non_hp' else 'completed' if case in {'success','powershell51_tools','package_restart'} else 'needs_attention'
    assert result['first']['status']==status,result
    calls=Path(str(tool)+'.calls')
    if case in {'success','powershell51_tools','package_restart','package_failure'}:
        args=json.loads(calls.read_text())
        assert all(arg in args for arg in ['/Operation:Analyze','/Category:All','/Selection:All','/Action:Install','/Silent','/AutoReport'])
        assert any(arg.startswith('/SoftpaqDownloadFolder:') for arg in args)
        assert '/Noninteractive' not in args and not any(arg.lower().startswith('/force') for arg in args)
        assert result['first']['reboot_required']==(case=='package_restart')
        assert result['first']['packages'][0]['code']==native_code
        assert result['first']['packages'][0]['softpaq_id']=='SP12345'
        assert len(list((data/'timings').glob('*.json')))==1
    elif case=='timeout':
        assert calls.exists() and 'aucun processus interrompu' in result['first']['message']
    else:assert not calls.exists()


def test_native_exit_codes_and_untrusted_xml(tmp_path):
    (tmp_path/'safe.xml').write_text('<HPIA><Remediation><ReturnCode>3010</ReturnCode><ReturnDescription>Restart required</ReturnDescription></Remediation></HPIA>')
    (tmp_path/'secret').write_text('PRIVATE VALUE')
    (tmp_path/'unsafe.xml').write_text('<!DOCTYPE a [<!ENTITY secret SYSTEM "'+(tmp_path/'secret').as_uri()+'">]><HPIA><Remediation><ReturnCode>0</ReturnCode><ReturnDescription>&secret;</ReturnDescription></Remediation></HPIA>')
    wrapper=tmp_path/'check.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
. 'LIBRARY'
@{codes=@(0,256,257,3010,3020,4096,999|ForEach-Object { Get-AtelierHpiaOutcome $_ });packages=@(Read-AtelierHpiaPackages 'FOLDER')}|ConvertTo-Json -Depth 6
""".replace('LIBRARY',ps(ROOT/'scripts'/'HP-ImageAssistant.ps1')).replace('FOLDER',ps(tmp_path)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    result=json.loads(run.stdout)
    assert [c['status'] for c in result['codes']]==['completed','completed','needs_attention','completed','needs_attention','needs_attention','needs_attention']
    assert result['codes'][3]['reboot_required'] is True
    assert len(result['packages'])==1 and result['packages'][0]['code']==3010
    assert 'PRIVATE VALUE' not in run.stdout
