"""Real PowerShell/native-process checkpoints; boot and shutdown are simulated."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH or os.name=='nt',reason='PowerShell/Linux native fixture required')


def ps(value):return str(value).replace("'","''")


@pytest.mark.parametrize('case',['bios','interrupted','driver','limit','unknown_boot'])
def test_checkpointed_hp_resume_requires_new_boot_and_reanalyses(tmp_path,case):
    data=tmp_path/'data';data.mkdir()
    program=tmp_path/'Program Files';tool=program/'AtelierPXE'/'Tools'/'hp'/'HPImageAssistant.exe';tool.parent.mkdir(parents=True)
    tool.write_text('''#!/usr/bin/env python3
import pathlib,sys,json
root=pathlib.Path(__file__).parent
checkpoint=json.loads(pathlib.Path('CHECKPOINT').read_text(encoding='utf-8-sig'))
assert checkpoint['status']=='running' and checkpoint['boot_id']
with (root/'calls').open('a') as out:out.write(json.dumps({'args':sys.argv[1:],'pass':checkpoint['pass_number']})+'\\n')
install='/Action:Install' in sys.argv[1:]
first=checkpoint['pass_number']==1
item={'Name':'System BIOS' if 'CASE'!='driver' else 'HP Audio Driver','Category':'BIOS' if 'CASE'!='driver' else 'Driver','SoftPaqID':'SP12345' if first else 'SP56789','Remediation':{'ReturnCode':3010 if first and install else 0,'ReturnDescription':'Restart required' if first else 'Applied'}}
pathlib.Path('HPIA.json').write_text(json.dumps({'HPIA':{'Recommendations':[item]}}))
'''.replace('CHECKPOINT',str(data/'hpia-result.json')).replace('CASE',case))
    tool.chmod(0o755)
    (data/'ready-tools.json').write_text(json.dumps([{'path':str(tool),'sha256':hashlib.sha256(tool.read_bytes()).hexdigest()}]))
    (data/'personalization.json').write_text(json.dumps({'deployment':{'id':'1f99fd15-f6ea-48ed-ab9c-0d8d7c27ad8f','hp_repository':True,'allow_bios_restart':True}}))
    (data/'HP-ClientRepository.ps1').write_text("function Get-AtelierHpRepository { param($DataPath,$RequiredSoftpaqs,$OnProgress,[switch]$PrepareOnly);return [pscustomobject]@{status='online';message='Test online'} }")
    if case=='limit':
        (data/'hpia-result.json').write_text(json.dumps({'status':'running','boot_id':'2026-10-19T00:00:00.0000000Z','resume_count':3,'pass_number':4,'process_id':12345,'exit_code':None,'report_directory':str(tmp_path/'IQ'/'Rapports'/'HPImageAssistant')}))
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
$env:ProgramFiles='PROGRAM'
$global:TestBoot=[datetime]'2026-10-20T00:00:00Z'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec)
 if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{LastBootUpTime=$(if ('CASE' -eq 'unknown_boot') { $null } else { $global:TestBoot })} }
 return [pscustomobject]@{Manufacturer='HP'}
}
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=HP Inc.'}}}
function shutdown.exe {
 $checkpoint=Get-Content 'DATA/hpia-result.json' -Raw|ConvertFrom-Json
 if ($checkpoint.status -ne 'reboot_pending' -or $checkpoint.reboot_requested_boot -ne $checkpoint.boot_id) { throw 'Checkpoint not durable before shutdown' }
 Add-Content 'DATA/shutdown-calls' 'shutdown'
 $global:LASTEXITCODE=0
}
. 'LIBRARY'
$first=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'IQ'
if ('CASE' -eq 'interrupted') {
 $interrupted=Get-Content 'DATA/hpia-result.json' -Raw|ConvertFrom-Json
 $interrupted.status='running';$interrupted.exit_code=$null
 $interrupted|ConvertTo-Json -Depth 14|Set-Content 'DATA/hpia-result.json'
}
if ('CASE' -eq 'bios') { Request-AtelierHpBiosRestart 'DATA';Request-AtelierHpBiosRestart 'DATA' }
$same=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'IQ'
$global:TestBoot=[datetime]'2026-10-21T00:00:00Z'
$resumed=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'IQ'
$again=Invoke-AtelierHpia -DataPath 'DATA' -ToolsPath 'IQ'
@{first=$first;same=$same;resumed=$resumed;again=$again}|ConvertTo-Json -Depth 16|Set-Content 'RESULT'
""".replace('PROGRAM',ps(program)).replace('LIBRARY',ps(ROOT/'scripts'/'HP-ImageAssistant.ps1')).replace('DATA',ps(data)).replace('IQ',ps(tmp_path/'IQ')).replace('RESULT',ps(tmp_path/'result.json')).replace('CASE',case))
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=40)
    assert run.returncode==0,run.stderr
    result=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))
    calls=[json.loads(line) for line in (tool.parent/'calls').read_text().splitlines()] if (tool.parent/'calls').exists() else []
    if case in {'limit','unknown_boot'}:
        assert result['first']['status']=='needs_attention' and not calls
        assert 'Limite' in result['first']['message'] if case=='limit' else 'démarrage' in result['first']['message']
        return
    assert [c['pass'] for c in calls]==([1,1] if case=='driver' else [1,1,2,2])
    assert '/Action:List' in calls[0]['args'] and '/Action:Install' in calls[1]['args']
    if case=='driver':
        assert result['first']['status']=='completed' and result['first']['reboot_required']
        assert result['resumed']['pass_number']==1
        assert not (data/'shutdown-calls').exists()
        return
    assert result['first']['status']=='reboot_pending'
    assert result['same']['status']==('retry_pending' if case=='interrupted' else 'reboot_pending')
    resumed=result['resumed']
    assert resumed['status']=='completed' and resumed['reboot_required'] is False
    assert resumed['resume_count']==1 and resumed['pass_number']==2 and resumed['resumed_after_reboot']
    assert resumed['packages'][0]['softpaq_id']=='SP56789'
    assert resumed['history'][0]['pass_number']==1 and resumed['history'][0]['packages'][0]['softpaq_id']=='SP12345'
    assert '/Action:List' in calls[2]['args'] and '/Action:Install' in calls[3]['args']
    reports=Path(resumed['report_directory'])
    assert (reports/'Passage-01'/'Installation'/'HPIA.json').exists()
    assert (reports/'Passage-02'/'Installation'/'HPIA.json').exists()
    if case=='bios':assert (data/'shutdown-calls').read_text().splitlines()==['shutdown']


@pytest.mark.parametrize('restart_ok',[True,False])
def test_maintenance_preserves_startup_task_until_bios_resume_and_clears_consumed_reboot(tmp_path,restart_ok):
    data=tmp_path/'data';data.mkdir()
    for name in ['Unattend.ps1','Client-Software.ps1']:
        shutil.copy(ROOT/'scripts'/name,data/name)
    (data/'Updates.ps1').write_text('function Disable-AtelierAutoLogon {}')
    (data/'personalization.json').write_text(json.dumps({'deployment':{'allow_bios_restart':True},'settings':{'winget_packages':['hpia'],'windows_update':True,'store_update':True}}))
    (data/'result.json').write_text(json.dumps({'status':'completed','software_status':'completed','restart_needed':True,'applications':[{'id':'hpia','status':'completed','verification':{'method':'fixture'}}]}))
    (data/'HP-ImageAssistant.ps1').write_text(""". 'LIBRARY'
function Invoke-AtelierHpia {
 param($DataPath,$ToolsPath,$OnProgress)
 $next=Get-Content (Join-Path $DataPath 'next-hp.json') -Raw|ConvertFrom-Json
 $checkpoint=@{};foreach($property in $next.PSObject.Properties){$checkpoint[$property.Name]=$property.Value}
 Save-AtelierHpCheckpoint (Join-Path $DataPath 'hpia-result.json') $checkpoint
 return $next
}
""".replace('LIBRARY',ps(ROOT/'scripts'/'HP-ImageAssistant.ps1')))
    pending={'status':'reboot_pending','message':'BIOS restart required','reboot_required':True,'boot_id':'2026-10-20T00:00:00.0000000Z','pass_number':1,'resume_count':0}
    (data/'next-hp.json').write_text(json.dumps(pending))
    wrapper=tmp_path/'maintenance.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
$global:TestBoot=[datetime]'2026-10-20T00:00:00Z'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);[pscustomobject]@{LastBootUpTime=$global:TestBoot}}
function Unregister-ScheduledTask { [CmdletBinding()]param($TaskName,[switch]$Confirm);Add-Content 'DATA/unregistered' $TaskName }
function shutdown.exe {
 $maintenance=Get-Content 'DATA/maintenance.json' -Raw|ConvertFrom-Json
 $hp=Get-Content 'DATA/hpia-result.json' -Raw|ConvertFrom-Json
 if($maintenance.status -ne 'reboot_pending' -or -not $hp.reboot_requested_boot){throw 'Missing durable state'}
 Add-Content 'DATA/shutdown' 'requested'
 $global:LASTEXITCODE=EXIT
}
& 'MAINTENANCE' -DataPath 'DATA' -ToolsPath 'IQ'
Copy-Item 'DATA/maintenance.json' 'DATA/before.json'
if(Test-Path 'DATA/unregistered'){throw 'Task removed before restart'}
# An ordinary same-boot retry must not duplicate shutdown or exhaust attempts.
$hp=Get-Content 'DATA/hpia-result.json' -Raw|ConvertFrom-Json
$hp|ConvertTo-Json -Depth 12|Set-Content 'DATA/next-hp.json'
& 'MAINTENANCE' -DataPath 'DATA' -ToolsPath 'IQ'
$global:TestBoot=[datetime]'2026-10-21T00:00:00Z'
@{status='completed';message='Remaining driver installed';reboot_required=$false;resumed_after_reboot=$true;boot_id='2026-10-21T00:00:00.0000000Z';pass_number=2;resume_count=1}|ConvertTo-Json|Set-Content 'DATA/next-hp.json'
& 'MAINTENANCE' -DataPath 'DATA' -ToolsPath 'IQ'
""".replace('MAINTENANCE',ps(ROOT/'scripts'/'Maintenance.ps1')).replace('DATA',ps(data)).replace('IQ',ps(tmp_path/'IQ')).replace('EXIT','0' if restart_ok else '5'))
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=40)
    assert run.returncode==0,run.stderr
    before=json.loads((data/'before.json').read_text())
    final=json.loads((data/'maintenance.json').read_text())
    assert before['status']=='reboot_pending' and before['attempts']==1
    if not restart_ok:assert 'non accepté' in before['message']
    assert (data/'shutdown').read_text().splitlines()==['requested']
    assert final['status']=='completed' and final['attempts']==1
    assert final['reboots']==1 and not final['reboot_required']
    assert final['windows']['status']==final['store']['status']=='manual'
    assert json.loads((data/'result.json').read_text())['restart_needed'] is False
    assert 'AtelierPXE-Maintenance' in (data/'unregistered').read_text()
