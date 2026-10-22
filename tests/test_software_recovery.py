"""Exercise false success, captured checkpoints and repair through native fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH or os.name=='nt',reason='PowerShell and Linux executable fixture required')


def setup_client(tmp_path,mode='success'):
    data=tmp_path/'data';data.mkdir()
    for file in (ROOT/'scripts').glob('*'):
        if file.is_file() and file.suffix in {'.ps1','.json','.png'}:
            shutil.copy(file,data/file.name)
    exe=tmp_path/'winget.exe'
    exe.write_text('''#!/usr/bin/env python3
import sys,json,pathlib,os
if sys.argv[1:]==['--version']:
 print('v1.12.0');sys.exit(0)
assert sys.argv[1:4]==['install','--id','VideoLAN.VLC']
with open(__file__+'.calls','a') as f:f.write('install\\n')
mode=os.environ['ATELIER_FIXTURE_MODE']
if mode=='failure':sys.exit(17)
if mode=='success':
 p=pathlib.Path(__file__).parent/'VLC';p.mkdir(exist_ok=True)
 (p/'vlc.exe').write_bytes(b'installed fixture')
 pathlib.Path(__file__+'.registry.json').write_text(json.dumps([dict(DisplayName='VLC media player',Publisher='VideoLAN',DisplayVersion='3.0.21',InstallLocation=str(p),DisplayIcon=str(p/'vlc.exe'))]))
''');exe.chmod(0o755)
    (data/'personalization.json').write_text(json.dumps({'settings':{'software_mode':'winget','winget_packages':['vlc'],'theme':'unchanged','central_inventory':False},'applications':[],'deployment':{'id':'new-deployment'}}))
    common="""$ErrorActionPreference='Stop'
$env:PATH='TEMP'+[IO.Path]::PathSeparator+$env:PATH
$env:SystemRoot='TEMP'
$env:ProgramFiles='TEMP/Program Files'
$env:ATELIER_FIXTURE_MODE='FIXTUREBEHAVIOR'
function Get-AppxPackage {param($Name)}
function Get-ItemProperty {
 param($Path,$Name)
 if ([string]$Path -match 'Uninstall') {
  if (Test-Path 'TEMP/winget.exe.registry.json') {Get-Content 'TEMP/winget.exe.registry.json' -Raw|ConvertFrom-Json}
 } else { [pscustomobject]@{HiberbootEnabled=0;EditionID='Professional'} }
}
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);[pscustomobject]@{Manufacturer='Lenovo';Model='Test';SerialNumber='TEST1234';TotalPhysicalMemory=16GB;Size=256GB}}
function Get-Process {param($Name);if($Name -eq 'explorer'){[pscustomobject]@{Id=123}}}
function Start-Process {}
function Get-ScheduledTask {param($TaskName);[pscustomobject]@{Principal=[pscustomobject]@{UserId='S-1-5-21-1000'}}}
function New-ScheduledTaskAction {@{}}
function New-ScheduledTaskTrigger {@{}}
function New-ScheduledTaskPrincipal {@{}}
function New-ScheduledTaskSettingsSet {@{}}
function Register-ScheduledTask {}
function Start-ScheduledTask {Set-Content 'DATA/maintenance-started' 'yes'}
function Unregister-ScheduledTask {}
function Start-AtelierTiming {return ''}
function Stop-AtelierTiming {}
function Sync-AtelierTimings {}
. 'DATA/Unattend.ps1'
. 'DATA/Client-Software.ps1'
""".replace('TEMP',str(tmp_path)).replace('DATA',str(data)).replace('FIXTUREBEHAVIOR',mode)
    # Avoid altering a real profile, license state or rebooting in this fixture.
    (data/'Updates.ps1').write_text('function Disable-AtelierAutoLogon {}')
    (data/'Prepare-IQTools.ps1').write_text('param($DataPath)')
    return data,exe,common


def run_ps(tmp_path,script):
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],text=True,capture_output=True,timeout=30)
    assert result.returncode==0,result.stderr+result.stdout
    return result


@pytest.mark.parametrize('case',['zero_exit','stale_checkpoint','damaged_checkpoint','registry_only','executable_only','failure','deleted_after_success'])
def test_native_success_requires_current_registration_and_executable(tmp_path,case):
    data,exe,script=setup_client(tmp_path,'failure' if case=='failure' else 'success' if case=='deleted_after_success' else 'no_op')
    if case=='stale_checkpoint':
        (data/'winget-client-state.json').write_text('[{"id":"vlc","status":"completed","reason":"old image"}]')
    if case=='damaged_checkpoint':
        (data/'winget-client-state.json').write_text('corrupted checkpoint from old payload')
    if case=='registry_only':
        Path(str(exe)+'.registry.json').write_text(json.dumps([{'DisplayName':'VLC media player','Publisher':'VideoLAN','InstallLocation':str(tmp_path/'VLC'),'DisplayVersion':'old'}]))
    if case=='executable_only':
        (tmp_path/'VLC').mkdir();(tmp_path/'VLC'/'vlc.exe').write_bytes(b'not registered')
    script+="""
$first=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @('vlc') -OnProgress {param($Percent,$Message)})
if ('CASE' -eq 'deleted_after_success') {
 Remove-Item -LiteralPath $first[0].verification.path
 $first=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @('vlc') -OnProgress {param($Percent,$Message)})
}
$summary=Get-AtelierSoftwareSummary -Packages @('vlc') -Results $first
@{entries=$first;summary=$summary}|ConvertTo-Json -Depth 8|Set-Content 'DATA/out.json'
""".replace('DATA',str(data)).replace('CASE',case)
    run_ps(tmp_path,script)
    result=json.loads((data/'out.json').read_text(encoding='utf-8-sig'))
    assert Path(str(exe)+'.calls').read_text().splitlines()==['install']*(2 if case=='deleted_after_success' else 1)
    if case=='deleted_after_success':
        assert result['summary']['status']=='completed'
        assert result['entries'][0]['verification']['method']=='registry_and_executable'
    else:
        assert result['entries'][0]['status']=='failed'
        assert result['summary']['status']=='needs_attention' and result['summary']['missing']==['vlc']
        assert json.loads((data/'winget-client-state.json').read_text())[0]['status']=='failed'


def test_winget_bootstrap_failure_has_per_package_results_and_preparation_log(tmp_path):
    data,_,script=setup_client(tmp_path)
    (data/'Install-WinGet.ps1').write_text("throw 'Network unavailable in first session'")
    script+="""
function Get-AtelierClientWinGet {return $null}
$result=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @('vlc','chrome') -OnProgress {param($Percent,$Message)})
ConvertTo-Json -InputObject $result|Set-Content 'DATA/out.json'
""".replace('DATA',str(data))
    run_ps(tmp_path,script)
    result=json.loads((data/'out.json').read_text(encoding='utf-8-sig'))
    assert len(result)==2 and all(e['status']=='failed' and 'Network unavailable' in e['reason'] for e in result)
    assert 'Network unavailable' in (data/'software-logs'/'winget-preparation.log').read_text(encoding='utf-8-sig')


@pytest.mark.parametrize('mode',['success','no_op','failure'])
def test_first_logon_rechecks_captured_completion_instead_of_skipping_software(tmp_path,mode):
    data,exe,script=setup_client(tmp_path,mode)
    # Replace the updater library after setup so its native opérations are inert.
    (data/'result.json').write_text('{"status":"completed","deployment_id":"reference-image","applications":[]}')
    (data/'Timings.ps1').write_text('function Start-AtelierTiming {return ""};function Stop-AtelierTiming {};function Sync-AtelierTimings {}')
    script+="\n& 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'\n".replace('DATA',str(data))
    run_ps(tmp_path,script)
    result=json.loads((data/'result.json').read_text(encoding='utf-8-sig'))
    assert result['deployment_id']=='new-deployment'
    if mode=='success':
        assert result['software_status']=='completed' and result['software_summary']['verified']==1
        assert result['applications'][0]['verification']['path'].endswith('vlc.exe')
    else:
        assert result['software_status']=='needs_attention' and result['software_summary']['missing']==['vlc']
    assert Path(str(exe)+'.calls').read_text().splitlines()==['install']
    assert (data/'maintenance-started').exists()


def test_repair_installs_only_original_selection_and_refreshes_final_status(tmp_path):
    data,exe,script=setup_client(tmp_path)
    (data/'result.json').write_text('{"status":"completed","applications":[]}')
    (data/'maintenance.json').write_text('{"status":"completed","message":"obsolète success"}')
    # Repair uses a source archive, and the target contains independent old files.
    source=tmp_path/'source';shutil.copytree(data,source)
    (data/'Export-Inventaire.ps1').write_text('param($OutputDirectory);New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null;Set-Content (Join-Path $OutputDirectory "Inventaire-Technique.xml") "fixture";Set-Content (Join-Path $OutputDirectory "Inventaire-Technique.csv") "fixture";[pscustomobject]@{SectionsIndisponibles=0}')
    script+="\n& 'SOURCE/Repair-Software.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'\n".replace('SOURCE',str(source)).replace('DATA',str(data))
    run_ps(tmp_path,script)
    result=json.loads((data/'result.json').read_text(encoding='utf-8-sig'))
    state=json.loads((data/'maintenance.json').read_text(encoding='utf-8-sig'))
    assert result['software_status']=='completed' and result['software_summary']['verified']==1
    assert state['status']=='completed' and 'Logiciels vérifiés : 1' in state['message']
    assert Path(str(exe)+'.calls').read_text().splitlines()==['install']
    assert len(list((data/'repair-backups').glob('software-*')))==1


@pytest.mark.parametrize('linked',[False,True])
def test_new_deployment_isolates_reference_computer_state_without_deleting_it(tmp_path,linked):
    old=tmp_path/'payload'
    reference=tmp_path/'reference';reference.mkdir()
    (reference/'result.json').write_text('{"status":"completed"}')
    if linked:old.symlink_to(reference,target_is_directory=True)
    else:shutil.copytree(reference,old)
    script="""
$ErrorActionPreference='Stop'
. 'LIBRARY'
try {
 $backup=Initialize-AtelierDeploymentPayload -Path 'PAYLOAD'
 @{status='ok';backup=$backup}|ConvertTo-Json|Set-Content 'OUTPUT'
} catch { @{status='refused';message=$_.Exception.Message}|ConvertTo-Json|Set-Content 'OUTPUT' }
""".replace('LIBRARY',str(ROOT/'scripts'/'Unattend.ps1')).replace('PAYLOAD',str(old)).replace('OUTPUT',str(tmp_path/'result.json'))
    run_ps(tmp_path,script)
    result=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))
    assert (reference/'result.json').is_file()
    if linked:
        assert result['status']=='refused' and old.is_symlink()
    else:
        assert result['status']=='ok' and not list(old.iterdir())
        assert json.loads((Path(result['backup'])/'result.json').read_text())['status']=='completed'


@pytest.mark.parametrize('register_first_session',[False,True])
def test_broken_winget_alias_falls_back_to_real_app_installer(tmp_path,register_first_session):
    bad=tmp_path/'bad.exe';bad.write_text('#!/bin/sh\nexit 0\n');bad.chmod(0o755)
    app=tmp_path/'app';app.mkdir()
    good=app/'winget.exe'
    if not register_first_session:
        good.write_text('#!/bin/sh\necho v1.12.0\n');good.chmod(0o755)
    script="""
$ErrorActionPreference='Stop'
function Get-Command {param($Name);[pscustomobject]@{Source='BAD'}}
function Get-AppxPackage {param($Name);[pscustomobject]@{InstallLocation='APP'}}
function Add-AppxPackage {
 param($MainPackage,[switch]$RegisterByFamilyName)
 [IO.File]::WriteAllText('GOOD',"#!/bin/sh`necho v1.12.0`n")
 & /bin/chmod +x 'GOOD'
 Set-Content 'REGISTERED' 'yes'
}
function Install-PackageProvider {throw 'No module bootstrap required after valid registration'}
. 'CLIENT'
if (REGISTER) { & 'BOOTSTRAP' }
$path=Get-AtelierClientWinGet
if ($path -ne 'GOOD') {throw 'Unusable alias incorrectly accepted'}
""".replace('BAD',str(bad)).replace('APP',str(app)).replace('GOOD',str(good))
    script=script.replace('REGISTERED',str(tmp_path/'registered')).replace('REGISTER','$true' if register_first_session else '$false').replace('CLIENT',str(ROOT/'scripts'/'Client-Software.ps1')).replace('BOOTSTRAP',str(ROOT/'scripts'/'Install-WinGet.ps1'))
    run_ps(tmp_path,script)
    assert (tmp_path/'registered').exists()==register_first_session
