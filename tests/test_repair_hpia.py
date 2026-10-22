"""Repair an already deployed HP, préserve other software and refuse active work."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['ready','active','not_hp'])
def test_repair_refreshes_hpia_only_after_preparation(tmp_path,case):
    source=tmp_path/'source';source.mkdir()
    data=tmp_path/'deployed';data.mkdir()
    shutil.copy(ROOT/'scripts'/'Repair-HPIA.ps1',source/'Repair-HPIA.ps1')
    shutil.copy(ROOT/'scripts'/'Unattend.ps1',data/'Unattend.ps1')
    (data/'result.json').write_text(json.dumps({'status':'completed','software_status':'needs_attention','restart_needed':False,'applications':[{'id':'vlc','name':'VLC','status':'completed'},{'id':'hpia','name':'HP Image Assistant','status':'failed'}]}))
    (data/'hpia-result.json').write_text('{"status":"needs_attention","message":"old missing tool"}')
    (data/'maintenance.json').write_text('{"status":"needs_attention","reboot_required":false}')
    (source/'Client-Software.ps1').write_text('''function Install-AtelierClientSoftware {
param($DataPath,$Packages,$OnProgress)
if ($Packages.Count -ne 1 -or $Packages[0] -ne 'hpia') {throw 'Only HPIA may be installed'}
[pscustomobject]@{id='hpia';name='HP Image Assistant';status='completed';exit_code=0;tool=@{path='HPImageAssistant.exe';sha256='fixture'}}
}''')
    (source/'Reporting.ps1').write_text('function Initialize-AtelierReportTrust {param($DataPath)}')
    (source/'HP-ImageAssistant.ps1').write_text('''function Invoke-AtelierHpia {
param($DataPath,$ToolsPath,$OnProgress)
if (Test-Path (Join-Path $DataPath 'hpia-result.json')) {throw 'Old HP failure must be archived before retry'}
[pscustomobject]@{status='completed';message='HP repaired';reboot_required=$false}
}''')
    (source/'New-DeploymentReport.ps1').write_text('''param($DataPath,$OutputDirectory,[switch]$RefreshInventory)
if (-not $RefreshInventory) {throw 'Inventory must be refreshed after driver installation'}
Set-Content (Join-Path $DataPath 'report-refreshed') 'yes'
''')
    for name in ['Install-WinGet.ps1','Timings.ps1','Maintenance.ps1','Updates.ps1','IQ-Paths.ps1','software-sources.json']:(source/name).write_text('# fixture')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);[pscustomobject]@{Manufacturer='MANUFACTURER'}}
function Get-ScheduledTask {param($TaskName,$ErrorAction);[pscustomobject]@{State='TASK_STATE'}}
function Get-Process {param($ErrorAction)}
& 'REPAIR' -DataPath 'DATA' -ToolsPath 'TOOLS'
""".replace('MANUFACTURER','Dell' if case=='not_hp' else 'HP').replace('TASK_STATE','Running' if case=='active' else 'Ready')
    .replace('REPAIR',str(source/'Repair-HPIA.ps1')).replace('DATA',str(data)).replace('TOOLS',str(tmp_path/'IQ')),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    if case!='ready':
        assert run.returncode!=0
        assert not (data/'repair-backups').exists()
        assert not (data/'report-refreshed').exists()
        return
    assert run.returncode==0,run.stdout+run.stderr
    result=json.loads((data/'result.json').read_text(encoding='utf-8-sig'))
    assert [a['id'] for a in result['applications']]==['vlc','hpia']
    assert result['software_status']=='completed'
    state=json.loads((data/'maintenance.json').read_text(encoding='utf-8-sig'))
    assert state['status']=='completed' and state['windows']['status']==state['store']['status']=='manual'
    assert (data/'report-refreshed').exists()
    assert len(list((data/'repair-backups').glob('*/hpia-result.json')))==1
