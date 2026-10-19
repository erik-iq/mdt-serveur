"""Install HPIA through the real client WinGet wrapper, then verify the executable."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH or os.name=='nt',reason='PowerShell and Linux executable fixture required')


def quote(path):return str(path).replace("'","''")


@pytest.mark.parametrize('case',['success','missing_exe','bad_publisher','winget_failure','deleted_after_success'])
def test_winget_hpia_location_validation_and_repair(tmp_path,case):
    shutil.copy(ROOT/'scripts'/'software-sources.json',tmp_path/'software-sources.json')
    program=tmp_path/'Program Files'
    executable=tmp_path/'winget.exe'
    executable.write_text('''#!/usr/bin/env python3
import sys,pathlib,json
args=sys.argv[1:]
assert args[:3]==['install','--id','HP.ImageAssistant']
assert '--silent' in args and '--disable-interactivity' in args
assert '--scope' not in args
with open(__file__+'.calls','a') as f:f.write(json.dumps(args)+'\\n')
if 'CASE'=='winget_failure':sys.exit(12)
if 'CASE'!='missing_exe':
    target=pathlib.Path(args[args.index('--location')+1])/'HPImageAssistant.exe'
    target.write_bytes(b'HP executable fixture, never executed')
'''.replace('CASE',case));executable.chmod(0o755)
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
$env:ProgramFiles='PROGRAM'
. 'CLIENT'
. 'FILES'
function Get-AtelierClientWinGet {return 'WINGET'}
function icacls.exe { $global:LASTEXITCODE=0 }
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='PUBLISHER'}}}
$first=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @('hpia') -OnProgress {param($Percent,$Message)})
if ('CASE' -eq 'deleted_after_success') {Remove-Item -LiteralPath $first[0].tool.path}
$second=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @('hpia') -OnProgress {param($Percent,$Message)})
@{first=$first;second=$second}|ConvertTo-Json -Depth 8|Set-Content 'RESULT' -Encoding UTF8
""".replace('PROGRAM',quote(program)).replace('CLIENT',quote(ROOT/'scripts'/'Client-Software.ps1'))
    .replace('FILES',quote(ROOT/'scripts'/'Unattend.ps1')).replace('WINGET',quote(executable))
    .replace('PUBLISHER','CN=Other company' if case=='bad_publisher' else 'CN=HP Inc., O=HP Inc.')
    .replace('DATA',quote(tmp_path)).replace('RESULT',quote(tmp_path/'result.json')).replace('CASE',case),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    result=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))
    expected='completed' if case in {'success','deleted_after_success'} else 'failed'
    assert result['first'][0]['status']==result['second'][0]['status']==expected,result
    calls=Path(str(executable)+'.calls').read_text().splitlines()
    assert len(calls)==(1 if case=='success' else 2)
    if expected=='completed':
        path=Path(result['second'][0]['tool']['path'])
        assert path==program/'AtelierPXE'/'Tools'/'HPImageAssistant'/'HPImageAssistant.exe'
        assert path.is_file() and len(result['second'][0]['tool']['sha256'])==64
    else:
        assert 'tool' not in result['second'][0]
        assert (tmp_path/'software-logs'/'hpia.log').exists()
