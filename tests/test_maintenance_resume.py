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
function shutdown.exe { $global:LASTEXITCODE=0 }
& 'WORKER' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
""".replace('WORKER',str(ROOT/'scripts'/'Maintenance.ps1').replace("'","''")).replace('DATA',str(tmp_path).replace("'","''")),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    return json.loads((tmp_path/'maintenance.json').read_text())


def test_reboot_resume_preserves_passes_and_finishes(tmp_path):
    first=run_worker(tmp_path,'reboot')
    assert first['status']=='reboot_pending' and first['reboots']==1 and first['passes']==1
    assert not (tmp_path/'autologon-disabled').exists()
    second=run_worker(tmp_path,'empty')
    assert second['status']=='completed' and second['reboots']==1 and second['passes']==2
    assert second['store']['status']=='requested' and not second['store']['completion_verified']
    assert (tmp_path/'autologon-disabled').exists()


def test_repeated_failures_stop_and_disable_autologon(tmp_path):
    for attempt in range(1,7):
        state=run_worker(tmp_path,'fail')
        assert state['attempts']==attempt
        assert state['status']==('needs_attention' if attempt==6 else 'retry_pending')
    assert (tmp_path/'autologon-disabled').exists()


def test_reboot_limit_prevents_loop(tmp_path):
    (tmp_path/'maintenance.json').write_text(json.dumps({'status':'reboot_pending','attempts':4,'passes':4,'reboots':4,'windows':None,'store':None,'message':'','timestamp':''}))
    state=run_worker(tmp_path,'reboot')
    assert state['status']=='needs_attention' and state['reboots']==4
    assert (tmp_path/'autologon-disabled').exists()


def test_package_reboot_happens_before_windows_updates(tmp_path):
    state=run_worker(tmp_path,'empty',package_restart=True)
    assert state['status']=='reboot_pending' and state['passes']==0
    assert state['reboots']==1
    state=run_worker(tmp_path,'empty',package_restart=True)
    assert state['status']=='completed' and state['reboots']==1
