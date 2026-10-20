"""Recognize official installed AnyDesk without accepting a portable file alone."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',[
    'normal','missing_publisher','missing_location','uninstall_path','icon_arguments',
    'service_only','service_other_path','legacy_signer','bad_signature','wrong_signer',
    'portable_only','registry_only',
])
def test_anydesk_requires_signed_binary_and_machine_registration(tmp_path,case):
    program=tmp_path/'Program Files (x86)'
    target=program/'AnyDesk'/'AnyDesk.exe'
    if case in {'uninstall_path','icon_arguments'}:target=tmp_path/'Enterprise apps'/'AnyDesk.exe'
    target.parent.mkdir(parents=True)
    if case!='registry_only':target.write_bytes(b'Official signed executable fixture, never executed')
    entry={'DisplayName':'AnyDesk','DisplayVersion':'ad 9.7.15','Publisher':'AnyDesk Software GmbH','InstallLocation':str(target.parent)}
    if case=='missing_publisher':entry.pop('Publisher')
    if case in {'missing_location','icon_arguments','uninstall_path'}:entry.pop('InstallLocation')
    if case=='uninstall_path':entry['UninstallString']='"'+str(target)+'" --uninstall'
    if case=='icon_arguments':entry['DisplayIcon']='"'+str(target)+'",0'
    entries=[] if case in {'service_only','service_other_path','portable_only'} else [entry]
    (tmp_path/'registry.json').write_text(json.dumps(entries))
    service={'PathName':'"'+str(target)+'" --service'} if case in {'service_only','service_other_path'} else None
    if case=='service_other_path':service['PathName']='"'+str(tmp_path/'missing'/'AnyDesk.exe')+'" --service'
    (tmp_path/'service.json').write_text(json.dumps(service))
    signer='CN=philandro Software GmbH, O=philandro Software GmbH' if case=='legacy_signer' else 'CN=Unrelated vendor' if case=='wrong_signer' else 'CN=AnyDesk Software GmbH, O=AnyDesk Software GmbH'
    script=r'''
$ErrorActionPreference='Stop'
$env:ProgramFiles='ROOT/Program Files'
${env:ProgramFiles(x86)}='ROOT/Program Files (x86)'
$env:ProgramW6432=$env:ProgramFiles
function Get-ItemProperty {param($Path);$records=Get-Content 'ROOT/registry.json' -Raw|ConvertFrom-Json;foreach($record in $records){$record}}
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec);Get-Content 'ROOT/service.json' -Raw|ConvertFrom-Json}
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status='SIGNATURE';SignerCertificate=[pscustomobject]@{Subject='SIGNER'}}}
. 'CLIENT'
$found=Get-AtelierInstalledClientSoftware 'anydesk'
ConvertTo-Json -InputObject $found -Depth 6|Set-Content 'ROOT/out.json'
'''.replace('ROOT',str(tmp_path)).replace('CLIENT',str(ROOT/'scripts'/'Client-Software.ps1')).replace('SIGNATURE','NotSigned' if case=='bad_signature' else 'Valid').replace('SIGNER',signer)
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    found=json.loads((tmp_path/'out.json').read_text(encoding='utf-8-sig'))
    rejected=case in {'service_other_path','bad_signature','wrong_signer','portable_only','registry_only'}
    if rejected:assert found is None
    else:
        assert Path(found['verification']['path'])==target
        assert found['verification']['method']==('signed_executable_and_service' if case=='service_only' else 'signed_executable_and_registry')


@pytest.mark.skipif(os.name=='nt',reason='Linux executable fixture')
@pytest.mark.parametrize('case',['installed','nonzero_installed','delayed_registration','missing'])
def test_anydesk_install_status_follows_verified_presence_and_preserves_native_code(tmp_path,case):
    shutil.copy(ROOT/'scripts'/'software-sources.json',tmp_path/'software-sources.json')
    exe=tmp_path/'winget.exe'
    exe.write_text('''#!/usr/bin/env python3
import pathlib,sys
args=sys.argv[1:]
assert args[args.index('--id')+1]=='AnyDesk.AnyDesk'
assert args[args.index('--architecture')+1]=='x86'
assert args[args.index('--scope')+1]=='machine'
pathlib.Path(__file__+'.called').write_text('yes')
sys.exit(19 if 'CASE'=='nonzero_installed' else 0)
'''.replace('CASE',case));exe.chmod(0o755)
    target=tmp_path/'Program Files (x86)'/'AnyDesk'/'AnyDesk.exe'
    target.parent.mkdir(parents=True);target.write_bytes(b'signed executable fixture')
    script=r'''
$ErrorActionPreference='Stop'
$env:ProgramFiles='ROOT/Program Files'
${env:ProgramFiles(x86)}='ROOT/Program Files (x86)'
$script:queries=0
function Get-ItemProperty {
 param($Path)
 if (-not (Test-Path 'ROOT/winget.exe.called')) {return}
 $script:queries++
 if ('CASE' -eq 'missing' -or ('CASE' -eq 'delayed_registration' -and $script:queries -lt 3)) {return}
 [pscustomobject]@{DisplayName='AnyDesk';DisplayVersion='9.7.15'}
}
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec)}
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=AnyDesk Software GmbH'}}}
. 'CLIENT'
. 'FILES'
function Get-AtelierClientWinGet {return 'ROOT/winget.exe'}
$results=@(Install-AtelierClientSoftware -DataPath 'ROOT' -Packages @('anydesk') -OnProgress {param($Percent,$Message)})
@{results=$results;summary=(Get-AtelierSoftwareSummary @('anydesk') $results)}|ConvertTo-Json -Depth 8|Set-Content 'ROOT/out.json'
'''.replace('ROOT',str(tmp_path)).replace('CLIENT',str(ROOT/'scripts'/'Client-Software.ps1')).replace('FILES',str(ROOT/'scripts'/'Unattend.ps1')).replace('CASE',case)
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    result=json.loads((tmp_path/'out.json').read_text(encoding='utf-8-sig'))
    entry=result['results'][0]
    assert entry['status']==('failed' if case=='missing' else 'completed')
    assert result['summary']['status']==('needs_attention' if case=='missing' else 'completed')
    assert entry['exit_code']==(19 if case=='nonzero_installed' else 0)
    assert 'Controle final' in (tmp_path/'software-logs'/'anydesk.log').read_text(encoding='utf-8-sig')
