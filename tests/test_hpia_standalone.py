"""Exercise the one-click SYSTEM launcher and real HPIA checkpoints without Windows deployment."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

import pytest

from test_hpia_generic_reference import ROOT, PWSH

pytestmark = pytest.mark.skipif(not PWSH or os.name == 'nt', reason='PowerShell/Linux native fixture required')


@pytest.mark.parametrize('case', ['success', 'failure', 'bios', 'active_preparation', 'bad_signature', 'registration_failure'])
def test_isolated_hp_test_has_no_deployment_credentials_and_resumes_only_its_bios_work(tmp_path, case):
    source = tmp_path / 'source'
    source.mkdir()
    for name in ('Test-HPIA.ps1', 'HP-ImageAssistant.ps1', 'Unattend.ps1'):
        text = (ROOT / 'scripts' / name).read_text().replace('#requires -RunAsAdministrator\n', '')
        (source / name).write_text(text)
    program = tmp_path / 'Program Files'
    exe = program / 'AtelierPXE/Tools/HPImageAssistant/HPImageAssistant.exe'
    exe.parent.mkdir(parents=True)
    exe.write_text('''#!/usr/bin/env python3
import json,pathlib,sys
root=pathlib.Path(__file__).parent
args=sys.argv[1:]
assert '/Action:Install' in args and '/InstallType:AutoInstallable' in args
assert '/IgnoreGenericOsError' in args and '/AutoReport' not in args and '/Force' not in args
assert not any('OfflineMode' in a for a in args)
with (root/'calls').open('a') as f:f.write(json.dumps(args)+'\\n')
second='Passage-02' in str(pathlib.Path.cwd())
code=1603 if 'CASE'=='failure' else (3010 if 'CASE'=='bios' and not second else 0)
item={'Name':'System BIOS' if 'CASE'=='bios' else 'HP Driver','Category':'BIOS' if 'CASE'=='bios' else 'Driver','SoftPaqID':'SP12345','Remediation':{'ReturnCode':code,'ReturnDescription':'Native fixture'}}
pathlib.Path('HPIA.json').write_text(json.dumps({'HPIA':{'HPIAOperation':'Analyze Action Install','LastOperation':'EndInstall','Recommendations':[item]}}))
pathlib.Path('Readme (20261021 152514).html').write_text('<html>Native installation summary</html>')
'''.replace('CASE', case))
    exe.chmod(0o755)
    old = tmp_path / 'original deployment'
    old.mkdir()
    (old / 'result.json').write_text('{"status":"completed","sentinel":"unchanged"}')
    original_hash = hashlib.sha256((old / 'result.json').read_bytes()).hexdigest()
    wrapper = tmp_path / 'test.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
$env:ProgramFiles='WORK/Program Files';$env:ProgramData='WORK';$env:SystemRoot='WORK/Windows'
$global:TestTask=$null;$global:TestStarts=0;$global:TestUnregisters=0;$global:TestShutdowns=0
$global:TestBoot=[datetime]'2026-10-21T00:00:00Z'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec)
 if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{LastBootUpTime=$global:TestBoot}}
 return [pscustomobject]@{Manufacturer='HP'}
}
function Get-Process {param($Name,$ErrorAction);return}
function Get-AuthenticodeSignature {param($LiteralPath);return [pscustomobject]@{Status=$(if('CASE' -eq 'bad_signature'){'NotSigned'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=HP Inc.'}}}
function icacls.exe {$global:LASTEXITCODE=0}
function Unblock-File {param($LiteralPath)}
function Get-ScheduledTask {param($TaskName,$ErrorAction)
 if($TaskName -eq 'AtelierPXE-Preparation' -and 'CASE' -eq 'active_preparation'){return [pscustomobject]@{State='Running'}}
 if($TaskName -eq 'AtelierPXE-HpiaTest'){return $global:TestTask}
 return $null
}
function New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory);return [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);return [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries);return [pscustomobject]@{ExecutionTimeLimit=$ExecutionTimeLimit;MultipleInstances=$MultipleInstances}}
function New-ScheduledTaskTrigger {param([switch]$AtStartup);return [pscustomobject]@{AtStartup=[bool]$AtStartup}}
function Register-ScheduledTask {
 [CmdletBinding()]param($TaskName,$Action,$Principal,$Settings,$Trigger,[switch]$Force)
 if('CASE' -eq 'registration_failure'){Write-Error 'Mock registration failed';return}
 $global:TestTask=[pscustomobject]@{State='Ready';Actions=@($Action);Principal=$Principal;Settings=$Settings;Trigger=$Trigger}
}
function Start-ScheduledTask {[CmdletBinding()]param($TaskName);$global:TestStarts++}
function Unregister-ScheduledTask {[CmdletBinding(SupportsShouldProcess)]param($TaskName);$global:TestUnregisters++;$global:TestTask=$null}
function shutdown.exe {
 if(-not $global:TestTask){throw 'Reboot requested without a startup task'}
 $global:TestShutdowns++;$global:LASTEXITCODE=0
}
$root='WORK/private test';$iq='WORK/IQ_'
$failed=$false;$message='';$result=$null;$resumed=$null;$blocked=$false;$principal=$null;$id=''
try {
 & 'WORK/source/Test-HPIA.ps1' -StateRoot $root -ToolsPath $iq
 $principal=$global:TestTask.Principal
 $id=(Get-Content (Join-Path $root 'active.json') -Raw|ConvertFrom-Json).run_id
 & (Join-Path $root 'Runner/Test-HPIA.ps1') -Run -StateRoot $root -ToolsPath $iq -RunId $id
 $state=Join-Path $root ('Runs/'+$id+'/hpia-result.json')
 $result=Get-Content $state -Raw|ConvertFrom-Json
 if('CASE' -eq 'bios'){
  try{& 'WORK/source/Test-HPIA.ps1' -StateRoot $root -ToolsPath $iq}catch{$blocked=$true}
  $global:TestBoot=[datetime]'2026-10-22T00:00:00Z'
  & (Join-Path $root 'Runner/Test-HPIA.ps1') -Run -StateRoot $root -ToolsPath $iq -RunId $id
  $resumed=Get-Content $state -Raw|ConvertFrom-Json
 }
}catch{$failed=$true;$message=$_.Exception.Message}
@{failed=$failed;message=$message;result=$result;resumed=$resumed;blocked=$blocked;principal=$principal;starts=$global:TestStarts;unregisters=$global:TestUnregisters;shutdowns=$global:TestShutdowns;run_id=$id}|ConvertTo-Json -Depth 18|Set-Content 'WORK/out.json'
'''.replace('WORK', str(tmp_path)).replace('CASE', case), encoding='utf-8-sig')
    run = subprocess.run([PWSH, '-NoProfile', '-File', str(wrapper)], capture_output=True, text=True, timeout=45)
    assert run.returncode == 0, run.stdout + run.stderr
    result = json.loads((tmp_path / 'out.json').read_text(encoding='utf-8-sig'))
    assert result['failed'] == (case in {'active_preparation', 'bad_signature', 'registration_failure'}), result
    assert hashlib.sha256((old / 'result.json').read_bytes()).hexdigest() == original_hash
    assert not list((tmp_path / 'private test').rglob('reporting.json'))
    if result['failed']:
        assert result['starts'] == 0
        assert not (exe.parent / 'calls').exists()
        return
    assert result['principal'] == {'UserId': 'S-1-5-18', 'LogonType': 'ServiceAccount', 'RunLevel': 'Highest'}
    assert result['starts'] == 1 and result['unregisters'] == 1
    if case == 'bios':
        assert result['result']['status'] == 'reboot_pending' and result['shutdowns'] == 1 and result['blocked']
        assert result['resumed']['status'] == 'completed' and result['resumed']['resume_count'] == 1
    else:
        assert result['result']['status'] == ('needs_attention' if case == 'failure' else 'completed')
        assert result['shutdowns'] == 0
    archive = tmp_path / 'IQ_/Rapports/HPImageAssistant/Tests' / (result['run_id'] + '.zip')
    with zipfile.ZipFile(archive) as z:
        assert 'hpia-result.json' in z.namelist()
        assert 'Rapport-Installation-HP.html' in z.namelist()
        assert any(n.endswith('HPIA.json') for n in z.namelist())
