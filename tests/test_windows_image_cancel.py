"""Cancel only a proven private candidate; never kill unrelated DISM or delete data."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell required')


@pytest.mark.parametrize('case', ['success', 'single_cim', 'unquoted_cim', 'export_cim', 'auto', 'auto_idle', 'already_stopped', 'discard_failure', 'foreign_mount',
    'foreign_task', 'wrong_candidate', 'wrong_run', 'no_matching_dism', 'ready_candidate', 'pid_reused', 'lock_busy','pre_dism','pre_dism_auto','pre_dism_foreign_owner','pre_dism_old_report','pre_dism_ambiguous'])
def test_cancel_protects_production_and_targets_only_candidate(tmp_path, case):
    scripts = tmp_path / 'scripts'
    scripts.mkdir()
    for name in ('Console-Installation.ps1', 'Windows-ImageServicing.ps1'):
        shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
    stop = (ROOT / 'scripts/Stop-WindowsImageMaintenance.ps1').read_text().replace('#requires -RunAsAdministrator\n', '')
    (scripts / 'Stop-WindowsImageMaintenance.ps1').write_text(stop)
    data = tmp_path / 'data'
    identifier = '20261021-103851-f52d8739'
    run = data / 'windows-servicing/runs' / identifier
    (run / 'mount').mkdir(parents=True)
    source = tmp_path / 'source.wim'
    source.write_bytes(b'production unchanged')
    candidate = run / 'candidate.wim'
    candidate.write_bytes(b'disposable candidate')
    backup = data / 'windows-servicing/backups/source.wim'
    backup.parent.mkdir()
    backup.write_bytes(source.read_bytes())
    report = {'run_id': identifier, 'source_path': str(source), 'candidate_path': str(candidate), 'status': 'preparing'}
    if case == 'wrong_candidate': report['candidate_path'] = str(source)
    if case == 'wrong_run': report['run_id'] = '20261020-103851-00000000'
    if case == 'ready_candidate': report['status'] = 'ready_for_test'
    if case.startswith('pre_dism'):
        candidate.unlink()
        report.update(active_stage='backup',started_at='2026-10-22T08:21:13Z')
        if case=='pre_dism_old_report':report['started_at']='2026-10-21T08:21:13Z'
    (run / 'report.json').write_text(json.dumps(report))
    console = tmp_path / 'console'
    console.mkdir()
    (console / 'data-runtime.json').write_text(json.dumps({'data_dir': str(data)}))
    wrapper = tmp_path / 'test.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
$global:cancelStopped=$false;$global:cancelDisabled=$false;$global:cancelUnmounted=$false
$global:cancelKilled=New-Object Collections.Generic.List[int]
$global:cancelActive='CASE' -notlike 'pre_dism*' -and 'CASE' -notin @('already_stopped','no_matching_dism','auto_idle')
$global:cancelMounted='CASE' -notlike 'pre_dism*' -and 'CASE' -notin @('export_cim','auto_idle')
function Get-ScheduledTask {
 [CmdletBinding()]param($TaskName)
 $script=Join-Path 'CONSOLE' 'scripts\Update-WindowsImage.ps1'
 if ('CASE' -eq 'foreign_task') { $script='unrelated.ps1' }
 [pscustomobject]@{State=$(if ('CASE' -in @('already_stopped','auto_idle') -or $global:cancelStopped){'Ready'}else{'Running'});Actions=@([pscustomobject]@{Arguments=('-File "'+$script+'"')})}
}
function Get-ScheduledTaskInfo {param($TaskName);[pscustomobject]@{LastRunTime=[datetime]'2026-10-22T08:10:54Z'}}
function Disable-ScheduledTask { [CmdletBinding()]param($TaskName);$global:cancelDisabled=$true }
function Stop-ScheduledTask { [CmdletBinding()]param($TaskName);$global:cancelStopped=$true }
function Get-CimInstance {
 [CmdletBinding()]param($ClassName,$Filter)
 if ($Filter -eq "Name='powershell.exe'") {
  $creation=if ('CASE' -eq 'pre_dism_foreign_owner') {'2026-10-21T08:10:54Z'}else{'2026-10-22T08:10:55Z'}
  $owner=[pscustomobject]@{ProcessId=10756;CreationDate=[datetime]$creation;CommandLine='powershell.exe -File "CONSOLE/scripts/Update-WindowsImage.ps1" -InstallPath "CONSOLE"'}
  $owner
  if ('CASE' -eq 'pre_dism_ambiguous') { $owner }
  return
 }
 $process=[pscustomobject]@{ProcessId=701;CreationDate='original';CommandLine='dism.exe /Unmount-Image /MountDir:"MOUNT" /Commit'}
 # PS 5.1 CIM adapters do not expose the scalar .Count used by PSCustomObject.
 if ('CASE' -in @('single_cim','unquoted_cim')) { $process | Add-Member NoteProperty Count $null }
 if ('CASE' -eq 'unquoted_cim') { $process.CommandLine=$process.CommandLine.Replace('"MOUNT"','MOUNT') }
 if ('CASE' -eq 'export_cim') { $process.CommandLine='dism.exe /Export-Image /SourceImageFile:"SOURCE" /DestinationImageFile:"CANDIDATE" /Compress:fast' }
 if ($Filter -like 'ProcessId=*') {
  if ('CASE' -eq 'pid_reused') { $process.CreationDate='new owner';$process.CommandLine='unrelated command' }
  return $process
 }
 if ($global:cancelActive) { $process }
 [pscustomobject]@{ProcessId=702;CreationDate='foreign';CommandLine='dism.exe /MountDir:"MOUNT-other" /Commit'}
}
function Stop-Process { [CmdletBinding()]param($Id,[switch]$Force);$global:cancelKilled.Add($Id);$global:cancelActive=$false }
function Get-WindowsImage {
 [CmdletBinding()]param([switch]$Mounted)
 if ($global:cancelMounted) { [pscustomobject]@{Path='MOUNT';ImagePath=$(if ('CASE' -eq 'foreign_mount'){'SOURCE'}else{'CANDIDATE'})} }
 [pscustomobject]@{Path='MOUNT-other';ImagePath='SOURCE'}
}
function Dismount-WindowsImage {
 [CmdletBinding()]param($Path,[switch]$Discard,$LogPath)
 if ($Path -ne 'MOUNT' -or -not $Discard) { throw 'Only discard of target mount is authorized' }
 if ('CASE' -eq 'discard_failure') { throw 'Mock discard failed' }
 $global:cancelUnmounted=$true;$global:cancelMounted=$false
}
function Start-Sleep { param($Milliseconds);if ('CASE' -eq 'pid_reused') { throw 'Reused PID still owns a foreign process' } }
$lock=$null
if ('CASE' -eq 'lock_busy') { $lock=[IO.File]::Open('LOCK',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
$failed=$false;$message=''
try {
 if ('CASE' -in @('auto','auto_idle','pre_dism_auto')) { & 'SCRIPTS/Stop-WindowsImageMaintenance.ps1' -InstallPath 'CONSOLE' -IfActive }
 else { & 'SCRIPTS/Stop-WindowsImageMaintenance.ps1' -InstallPath 'CONSOLE' -RunId '20261021-103851-f52d8739' }
}
catch { $failed=$true;$message=$_.Exception.Message }
finally { if ($lock) { $lock.Dispose() } }
@{failed=$failed;message=$message;disabled=$global:cancelDisabled;stopped=$global:cancelStopped;unmounted=$global:cancelUnmounted;killed=@($global:cancelKilled.ToArray())} | ConvertTo-Json -Compress
'''.replace('CASE', case).replace('SCRIPTS', str(scripts)).replace('CONSOLE', str(console))
        .replace('MOUNT', str(run / 'mount')).replace('CANDIDATE', str(candidate)).replace('SOURCE', str(source))
        .replace('LOCK', str(data / 'windows-servicing/maintenance.lock')))
    result = subprocess.run([PWSH, '-NoProfile', '-File', str(wrapper)], capture_output=True, text=True, timeout=45)
    assert result.returncode == 0, result.stdout + result.stderr
    state = json.loads(result.stdout.splitlines()[-1])
    successes = {'pre_dism','pre_dism_auto','success', 'single_cim', 'unquoted_cim', 'export_cim', 'already_stopped', 'auto', 'auto_idle'}
    assert state['failed'] == (case not in successes), state
    assert source.read_bytes() == backup.read_bytes() == b'production unchanged'
    if not case.startswith('pre_dism'):assert candidate.read_bytes() == b'disposable candidate'
    assert 702 not in state['killed']
    if case in {'foreign_mount', 'foreign_task', 'wrong_candidate', 'wrong_run', 'no_matching_dism', 'ready_candidate', 'auto_idle','pre_dism_foreign_owner','pre_dism_old_report','pre_dism_ambiguous'}:
        assert not state['disabled'] and not state['stopped'] and not state['killed'] and not state['unmounted']
    if case in {'success', 'single_cim', 'unquoted_cim', 'export_cim', 'discard_failure', 'auto'}:
        assert state['disabled'] and state['stopped'] and state['killed'] == [701]
    if case in successes - {'auto_idle'}:
        assert state['unmounted'] == (case not in {'export_cim','pre_dism','pre_dism_auto'})
        if case.startswith('pre_dism'):assert state['stopped'] and state['disabled'] and not state['killed']
        assert json.loads((run / 'report.json').read_text())['status'] == 'cancelled'
    elif case in {'discard_failure', 'pid_reused'}:
        assert json.loads((run / 'report.json').read_text())['status'] == 'cancelled_cleanup_required'
    if case in {'pid_reused', 'lock_busy'}:
        assert not state['killed'] and not state['unmounted']
