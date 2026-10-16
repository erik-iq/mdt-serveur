"""Exercise durable update state and reboot/retry limits with Windows calls stubbed."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def run_worker(tmp_path,case,package_restart=False):
    shutil.copy(ROOT/'scripts'/'Unattend.ps1',tmp_path/'Unattend.ps1')
    (tmp_path/'personalization.json').write_text(json.dumps({'settings':{'windows_update':True,'store_update':True}}))
    (tmp_path/'result.json').write_text(json.dumps({'status':'completed','restart_needed':package_restart}))
    updates=r'''
function Invoke-AtelierWindowsUpdates {
    if ('CASE' -eq 'fail') { throw 'Network unavailable' }
    [pscustomobject]@{status=$(if('CASE' -eq 'reboot'){'installed'}else{'up_to_date'});count=0;reboot_required=('CASE' -eq 'reboot');titles=@()}
}
function Request-AtelierStoreUpdates { [pscustomobject]@{status='requested';completion_verified=$false} }
function Disable-AtelierAutoLogon { [IO.File]::WriteAllText((Join-Path $DataPath 'autologon-disabled'),'yes') }
'''.replace('CASE',case)
    (tmp_path/'Updates.ps1').write_text(updates,encoding='utf-8-sig')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text("""
$ErrorActionPreference='Stop'
function Unregister-ScheduledTask { [CmdletBinding()] param($TaskName,[switch]$Confirm) }
function shutdown.exe { throw 'No forced reboot is allowed' }
& 'WORKER' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
""".replace('WORKER',str(ROOT/'scripts'/'Maintenance.ps1').replace("'","''")).replace('DATA',str(tmp_path).replace("'","''")),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    return json.loads((tmp_path/'maintenance.json').read_text())


def test_update_reboot_is_reported_without_interrupting_desktop_or_rescanning(tmp_path):
    first=run_worker(tmp_path,'reboot')
    assert first['status']=='needs_attention' and first['reboots']==0 and first['passes']==1
    assert first['reboot_required'] is True
    assert (tmp_path/'autologon-disabled').exists()
    second=run_worker(tmp_path,'fail')
    assert second['status']=='needs_attention' and second['attempts']==1 and second['passes']==1
    assert second['store']['status']=='requested' and not second['store']['completion_verified']


def test_search_failure_is_reported_once_and_store_continues(tmp_path):
    state=run_worker(tmp_path,'fail')
    assert state['status']=='needs_attention' and state['attempts']==1
    assert state['windows']['status']=='deferred' and 'Network unavailable' in state['message']
    assert state['store']['status']=='requested'
    assert (tmp_path/'autologon-disabled').exists()
    state=run_worker(tmp_path,'empty')
    assert state['status']=='needs_attention' and state['attempts']==1


def test_old_retry_state_is_closed_without_automatic_reboot_or_update_loop(tmp_path):
    (tmp_path/'maintenance.json').write_text(json.dumps({'status':'reboot_pending','attempts':4,'passes':4,'reboots':4,'windows':None,'store':None,'message':'','timestamp':''}))
    state=run_worker(tmp_path,'reboot')
    assert state['status']=='needs_attention' and state['reboots']==4 and state['passes']==4
    assert (tmp_path/'autologon-disabled').exists()


def test_package_reboot_is_reported_and_does_not_block_update_scan(tmp_path):
    state=run_worker(tmp_path,'empty',package_restart=True)
    assert state['status']=='needs_attention' and state['passes']==1
    assert state['reboots']==0 and state['reboot_required'] is True
    assert state['windows']['status']=='up_to_date'


def test_completed_worker_only_retries_report_without_reinstall(tmp_path):
    run_worker(tmp_path,'empty')
    (tmp_path/'Reporting.ps1').write_text(r'''
function Complete-AtelierReport {
    param($DataPath,$ToolsPath)
    [IO.File]::WriteAllText((Join-Path $DataPath 'report-retried'),'yes')
}
''',encoding='utf-8-sig')
    # The update engine now throws: completed state must never call it again.
    state=run_worker(tmp_path,'fail')
    assert state['status']=='completed' and state['attempts']==1
    assert (tmp_path/'report-retried').exists()
