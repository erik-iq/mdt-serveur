"""Finalization must never invoke Windows/Store updates, even with legacy flags."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def run_worker(tmp_path,hp_status='completed',package_restart=False,hp_restart=False,packages=None):
    shutil.copy(ROOT/'scripts'/'Unattend.ps1',tmp_path/'Unattend.ps1')
    (tmp_path/'personalization.json').write_text(json.dumps({'settings':{'windows_update':True,'store_update':True,'winget_packages':['hpia'] if packages is None else packages}}))
    (tmp_path/'result.json').write_text(json.dumps({'status':'completed','restart_needed':package_restart}))
    (tmp_path/'Updates.ps1').write_text(r'''
function Invoke-AtelierWindowsUpdates { Set-Content (Join-Path $DataPath 'forbidden-scan') 'Windows';throw 'Forbidden Windows scan' }
function Request-AtelierStoreUpdates { Set-Content (Join-Path $DataPath 'forbidden-scan') 'Store';throw 'Forbidden Store scan' }
function Disable-AtelierAutoLogon { [IO.File]::WriteAllText((Join-Path $DataPath 'autologon-disabled'),'yes') }
''',encoding='utf-8-sig')
    (tmp_path/'HP-ImageAssistant.ps1').write_text(r'''
function Invoke-AtelierHpia {
 param($DataPath,$ToolsPath,$OnProgress)
 Add-Content (Join-Path $DataPath 'hp-calls') 'run'
 & $OnProgress 'Analyse des SoftPaq HP'
 [pscustomobject]@{status='HP_STATUS';message='Resultat HP simule';reboot_required=HP_RESTART}
}
'''.replace('HP_STATUS',hp_status).replace('HP_RESTART','$true' if hp_restart else '$false'),encoding='utf-8-sig')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text("""
$ErrorActionPreference='Stop'
function Unregister-ScheduledTask { [CmdletBinding()] param($TaskName,[switch]$Confirm) }
function shutdown.exe { throw 'No forced reboot is allowed' }
function Restart-Computer { throw 'No forced reboot is allowed' }
& 'WORKER' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
""".replace('WORKER',str(ROOT/'scripts'/'Maintenance.ps1').replace("'","''")).replace('DATA',str(tmp_path).replace("'","''")),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    assert not (tmp_path/'forbidden-scan').exists()
    return json.loads((tmp_path/'maintenance.json').read_text())


def test_legacy_update_flags_are_ignored_and_hp_runs_before_completion(tmp_path):
    state=run_worker(tmp_path)
    assert state['status']=='completed' and state['passes']==0
    assert state['windows']['status']==state['store']['status']=='manual'
    assert state['hpia']['status']=='completed'
    assert (tmp_path/'autologon-disabled').exists()
    assert (tmp_path/'hp-calls').read_text().splitlines()==['run']


@pytest.mark.parametrize('source',['hp','package'])
def test_requested_restart_is_reported_but_never_started(tmp_path,source):
    state=run_worker(tmp_path,package_restart=source=='package',hp_restart=source=='hp')
    assert state['status']=='needs_attention' and state['reboot_required'] is True
    assert state['passes']==state['reboots']==0
    assert 'Redemarrage necessaire' in state['message']


def test_hp_failure_is_visible_without_reintroducing_update_scans(tmp_path):
    state=run_worker(tmp_path,hp_status='needs_attention')
    assert state['status']=='needs_attention' and state['attempts']==1
    assert 'Resultat HP simule' in state['message']


def test_old_pending_reboot_is_preserved_without_rescanning(tmp_path):
    (tmp_path/'maintenance.json').write_text(json.dumps({'status':'reboot_pending','attempts':4,'passes':4,'reboots':4,'windows':None,'store':None,'message':'','timestamp':''}))
    state=run_worker(tmp_path)
    assert state['status']=='needs_attention' and state['reboot_required']
    assert state['passes']==state['reboots']==4
    assert state['windows']['status']=='manual'


def test_completed_worker_only_retries_report_without_reinstall(tmp_path):
    run_worker(tmp_path)
    (tmp_path/'Reporting.ps1').write_text(r'''
function Complete-AtelierReport {
    param($DataPath,$ToolsPath)
    [IO.File]::WriteAllText((Join-Path $DataPath 'report-retried'),'yes')
}
''',encoding='utf-8-sig')
    state=run_worker(tmp_path,hp_status='needs_attention')
    assert state['status']=='completed' and state['attempts']==1
    assert (tmp_path/'report-retried').exists()
    assert (tmp_path/'hp-calls').read_text().splitlines()==['run']


@pytest.mark.parametrize('packages',[[],['vlc'],['lenovo_system_update']])
def test_unchecked_hpia_never_runs_softpaqs_even_with_an_old_result(tmp_path,packages):
    (tmp_path/'hpia-result.json').write_text('{"status":"completed","message":"old HP run"}')
    state=run_worker(tmp_path,packages=packages)
    assert state['status']=='completed'
    assert state['hpia']['status']=='skipped' and 'non coche' in state['hpia']['message']
    assert not (tmp_path/'hp-calls').exists()
