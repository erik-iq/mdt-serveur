import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['working_directory','script_argument','explicit','wrong_machine','missing_config'])
def test_find_installed_console_from_task_without_creating_config(tmp_path,case):
    installed=tmp_path/'custom installation with spaces'
    installed.mkdir()
    if case not in ('wrong_machine','missing_config'):(installed/'data-runtime.json').write_text('{}')
    wrapper=tmp_path/'resolve.ps1'
    working=str(installed) if case in ('working_directory','missing_config') else ''
    args='"'+str(installed/'scripts'/'serve.py')+'"' if case=='script_argument' else ''
    wrapper.write_text("""
$ErrorActionPreference='Stop'
. 'HELPER'
$env:COMPUTERNAME='TEST'
function Get-ScheduledTask { param($TaskName,$ErrorAction);TASK }
try { @{status='found';path=(Resolve-AtelierConsoleInstallation EXPLICIT)} | ConvertTo-Json -Compress }
catch { @{status='missing';message=$_.Exception.Message} | ConvertTo-Json -Compress }
""".replace('HELPER',str(ROOT/'scripts'/'Console-Installation.ps1')).replace('TASK',"return $null" if case=='wrong_machine' else "[pscustomobject]@{Actions=@([pscustomobject]@{WorkingDirectory='"+working+"';Arguments='"+args+"';Execute=''})}").replace('EXPLICIT',"-InstallPath '"+str(installed)+"'" if case=='explicit' else ''),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=20)
    assert run.returncode==0,run.stderr
    result=json.loads(run.stdout)
    assert result['status']==('missing' if case in ('wrong_machine','missing_config') else 'found'), result
    assert (installed/'data-runtime.json').exists()==(case not in ('wrong_machine','missing_config'))
