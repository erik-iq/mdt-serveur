"""Publish a bounded web status mirror while leaving mounts and private reports private."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
def test_status_mirror_includes_stage_durations_and_excludes_mounted_tree_from_storage(tmp_path):
    data=tmp_path/'data'
    run=data/'windows-servicing/runs/20261021-103851-f52d8739'
    (run/'mount').mkdir(parents=True)
    (run/'mount/ignore-mounted-windows.bin').write_bytes(b'x'*100000)
    (run/'candidate.wim').write_bytes(b'candidate fixture')
    backup=data/'windows-servicing/backups';backup.mkdir();(backup/'source.wim').write_bytes(b'original')
    script=tmp_path/'status.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/Windows-ImageServicing.ps1'
function Get-ScheduledTask {param($TaskName,$ErrorAction);[pscustomobject]@{State='Disabled'}}
function Get-ScheduledTaskInfo {param($TaskName,$ErrorAction);[pscustomobject]@{LastTaskResult=1;LastRunTime=[datetime]'2026-10-21T10:00:00Z'}}
$report=[ordered]@{run_id='20261021-103851-f52d8739';status='preparing';active_stage='';active_index=0;updated_at='';timings=@()}
Invoke-AtelierServicingStage -Report $report -Run 'RUN' -Name 'commit' -Index 2 -Action { }
Publish-AtelierServicingStatus -DataRoot 'DATA'
@{report=(Get-Content 'DATA/maintenance-overview/runs/20261021-103851-f52d8739.json' -Raw | ConvertFrom-Json);status=(Get-Content 'DATA/maintenance-overview/status.json' -Raw | ConvertFrom-Json)} | ConvertTo-Json -Depth 12 -Compress
'''.replace('PROJECT',str(ROOT)).replace('RUN',str(run)).replace('DATA',str(data)))
    process=subprocess.run([PWSH,'-NoProfile','-File',str(script)],text=True,capture_output=True,timeout=45)
    assert process.returncode==0,process.stdout+process.stderr
    value=json.loads(process.stdout.splitlines()[-1])
    assert value['report']['active_stage']=='commit' and value['report']['active_index']==2
    assert value['report']['timings'][0]['stage']=='commit'
    assert value['report']['timings'][0]['duration_seconds']>=0
    assert value['status']['task_state']=='Disabled'
    assert value['status']['candidates'][0]['present']
    assert value['status']['candidates'][0]['size']==len(b'candidate fixture')
    runs=next(s for s in value['status']['storage'] if s['name']=='runs')
    assert runs['bytes']<100000
    assert (run/'mount/ignore-mounted-windows.bin').stat().st_size==100000


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
def test_failed_web_mirror_does_not_fail_private_maintenance_report(tmp_path):
    data=tmp_path/'data';run=data/'windows-servicing/runs/20261021-103851-f52d8739'
    run.mkdir(parents=True)
    # A regular file blocks the optional directory, without touching the private report.
    (data/'maintenance-overview').write_text('unavailable web mirror fixture')
    script=tmp_path/'write.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/Windows-ImageServicing.ps1'
Write-AtelierServicingJson @{run_id='20261021-103851-f52d8739';status='ready_for_test'} 'RUN/report.json'
Get-Content 'RUN/report.json' -Raw
'''.replace('PROJECT',str(ROOT)).replace('RUN',str(run)))
    process=subprocess.run([PWSH,'-NoProfile','-File',str(script)],text=True,capture_output=True,timeout=30)
    assert process.returncode==0,process.stdout+process.stderr
    assert json.loads((run/'report.json').read_text())['status']=='ready_for_test'
    assert (data/'maintenance-overview').read_text()=='unavailable web mirror fixture'
