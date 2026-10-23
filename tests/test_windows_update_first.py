"""Windows Update précède les logiciels, avec reprises SYSTEM et arrêt sur erreur."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest
from test_software_recovery import setup_client, run_ps

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell requis')


@pytest.mark.parametrize('mode', ['completed', 'retry_completed', 'sharing_completed', 'needs_attention'])
def test_first_logon_waits_for_verified_updates_before_installing_apps(tmp_path, mode):
    data, exe, script = setup_client(tmp_path)
    payload = json.loads((data/'personalization.json').read_text())
    payload['deployment']['automatic_windows_update'] = True
    (data/'personalization.json').write_text(json.dumps(payload))
    (data/'Timings.ps1').write_text('function Start-AtelierTiming {return ""};function Stop-AtelierTiming {};function Sync-AtelierTimings {}')
    if mode == 'sharing_completed':
        with (data/'Unattend.ps1').open('a',encoding='utf-8') as handle:
            handle.write('''
function Read-AtelierSharedUtf8File {
 param($Path)
 $global:readChecks++
 if($global:readChecks -le 2){throw [IO.IOException]::new('Partage temporaire',-2147024864)}
 Get-Content $Path -Raw -Encoding UTF8
}
''')
    script += r'''
function Start-ScheduledTask {
 param($TaskName)
 if($TaskName -eq 'AtelierPXE-WindowsUpdateFirst'){
  if(Test-Path 'EXE.calls'){throw 'Logiciel lancé avant Windows Update'}
  @{source='windows_update';status='STATUS';message='Fixture'}|ConvertTo-Json|Set-Content 'DATA/windows-update-result.json'
 }else{Set-Content 'DATA/maintenance-started' 'yes'}
}
function Start-Sleep {
 param($Seconds)
 if(Test-Path 'EXE.calls'){throw 'Logiciel lancé pendant la recherche'}
 @{source='windows_update';status='completed';message='Vérifié'}|ConvertTo-Json|Set-Content 'DATA/windows-update-result.json'
 Set-Content 'DATA/waited' 'yes'
}
try { & 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_' }
catch {if('MODE' -ne 'needs_attention'){throw}}
'''.replace('DATA', str(data)).replace('EXE', str(exe)).replace('MODE', mode).replace('STATUS', 'retry_pending' if mode == 'retry_completed' else 'completed' if mode == 'sharing_completed' else mode)
    run_ps(tmp_path, script)
    result = json.loads((data/'result.json').read_text('utf-8-sig'))
    if mode == 'needs_attention':
        assert result['status'] == 'failed'
        assert not Path(str(exe)+'.calls').exists()
        assert not (data/'maintenance-started').exists()
    else:
        assert result['status'] == 'completed'
        assert Path(str(exe)+'.calls').read_text().splitlines() == ['install']
        assert (data/'maintenance-started').exists()
        if mode == 'retry_completed':
            assert (data/'waited').exists()


@pytest.mark.parametrize('mode', ['completed', 'retry_pending', 'installing', 'needs_attention', 'reboot', 'shutdown_failure', 'account_disabled', 'exception', 'sharing_error'])
def test_system_worker_preserves_restarts_and_never_releases_unknown_results(tmp_path, mode):
    shutil.copy(ROOT/'scripts/WindowsUpdate-First.ps1', tmp_path)
    (tmp_path/'personalization.json').write_text(json.dumps({'settings': {'unattended': True},'deployment': {'automatic_windows_update': True}}))
    (tmp_path/'Unattend.ps1').write_text('''
function Write-AtelierVerifiedUtf8File {param($Path,$Content,[switch]$NoBackup);[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))}
function Read-AtelierSharedUtf8File {param($Path);Get-Content $Path -Raw -Encoding UTF8}
function Test-AtelierFileSharingViolation {param($Exception);while($Exception.InnerException){$Exception=$Exception.InnerException};return ($Exception -is [IO.IOException]) -and (($Exception.HResult -band 0xFFFF) -in @(32,33))}
''')
    (tmp_path/'Reporting.ps1').write_text('function Initialize-AtelierReportTrust {};function Send-AtelierWindowsProgress {}')
    (tmp_path/'HP-ImageAssistant.ps1').write_text('function Get-AtelierHpBootIdentity {return $global:boot}')
    (tmp_path/'Client-WindowsUpdate.ps1').write_text('''
function Invoke-AtelierAutomaticWindowsUpdate {
 param($DataPath,$OnProgress)
 if($global:mode -eq 'exception'){throw 'Erreur de recherche'}
 if($global:mode -eq 'sharing_error'){throw [IO.IOException]::new('Partage temporaire',-2147024864)}
 $status=if($global:mode -in @('reboot','shutdown_failure','account_disabled')){if($global:boot -eq 'boot1'){'reboot_pending'}else{'completed'}}else{$global:mode}
 $wu=[pscustomobject]@{source='windows_update';status=$status;message='Fixture';restarts=1}
 $wu|ConvertTo-Json|Set-Content (Join-Path $DataPath 'windows-update-result.json')
 return $wu
}
''')
    wrapper = tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop';$global:mode='MODE';$global:boot='boot1'
function Unregister-ScheduledTask {[CmdletBinding()]param($TaskName,[switch]$Confirm);Add-Content 'DATA/unregistered' $TaskName}
function Get-LocalUser {[pscustomobject]@{Name='Administrateur';SID=[pscustomobject]@{Value='S-1-5-21-123-500'};Enabled=($global:mode -ne 'account_disabled')}}
function Set-ItemProperty {param($Path,$Name,$Value);if($Name -eq 'AutoAdminLogon'){Set-Content 'DATA/autologon' $Value}}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force)}
function shutdown.exe {
 param([Parameter(ValueFromRemainingArguments)]$Arguments)
 $restart=Get-Content 'DATA/windows-update-first-restart.json' -Raw|ConvertFrom-Json
 if($restart.boot_id -ne 'boot1'){throw 'Reprise non enregistrée avant redémarrage'}
 Add-Content 'DATA/shutdowns' 'yes'
 $global:LASTEXITCODE=if($global:mode -eq 'shutdown_failure'){1}else{0}
}
. 'DATA/WindowsUpdate-First.ps1' -DataPath 'DATA'
Invoke-AtelierWindowsUpdateFirstWorker -DataPath 'DATA'
if(Test-Path 'DATA/maintenance.json'){Copy-Item 'DATA/maintenance.json' 'DATA/first.json'}
if($global:mode -eq 'reboot'){
 Invoke-AtelierWindowsUpdateFirstWorker -DataPath 'DATA'
 $global:boot='boot2'
 Invoke-AtelierWindowsUpdateFirstWorker -DataPath 'DATA'
}
'''.replace('DATA', str(tmp_path)).replace('MODE', mode), encoding='utf-8-sig')
    run = subprocess.run([PWSH, '-NoProfile', '-File', str(wrapper)], text=True, capture_output=True, timeout=15)
    assert run.returncode == 0, run.stderr + run.stdout
    if mode == 'sharing_error':
        assert not (tmp_path/'unregistered').exists()
        assert not (tmp_path/'windows-update-result.json').exists()
        assert 'nouvelle tentative automatique' in (tmp_path/'maintenance.log').read_text('utf-8-sig')
        return
    first = json.loads((tmp_path/'first.json').read_text('utf-8-sig'))
    final = json.loads((tmp_path/'windows-update-result.json').read_text('utf-8-sig'))
    if mode == 'reboot':
        assert first['status'] == 'reboot_pending'
        assert final['status'] == 'completed'
        assert (tmp_path/'shutdowns').read_text().splitlines() == ['yes']
        assert (tmp_path/'autologon').read_text().strip() == '1'
    elif mode in ('shutdown_failure', 'account_disabled', 'exception', 'needs_attention'):
        assert first['status'] == 'needs_attention' and final['status'] == 'needs_attention'
        assert (tmp_path/'unregistered').exists()
    elif mode == 'completed':
        assert first['status'] == 'running' and first['windows']['status'] == 'completed'
        assert (tmp_path/'unregistered').exists()
    else:
        assert first['status'] == 'running' and final['status'] == mode
        assert not (tmp_path/'unregistered').exists()


def test_first_stage_is_embedded_in_deployment_and_winpe():
    for name in ('Build-WinPE.ps1', 'Deploy.ps1'):
        assert "'WindowsUpdate-First.ps1'" in (ROOT/'scripts'/name).read_text('utf-8-sig')


@pytest.mark.parametrize('phase',['absent','failed'])
def test_old_maintenance_task_does_not_finalize_the_update_first_phase(tmp_path,phase):
    for name in ('Unattend.ps1','IQ-Paths.ps1','Maintenance.ps1'):
        shutil.copy(ROOT/'scripts'/name,tmp_path)
    for name in ('Updates.ps1','HP-ImageAssistant.ps1'):
        (tmp_path/name).write_text('')
    (tmp_path/'Client-Software.ps1').write_text("function Get-AtelierSoftwareSummary {throw 'La maintenance ne doit pas encore examiner les logiciels'}")
    (tmp_path/'Reporting.ps1').write_text("function Complete-AtelierReport {param($DataPath,$ToolsPath);Set-Content (Join-Path $DataPath 'finalized') 'yes'}")
    (tmp_path/'personalization.json').write_text(json.dumps({'deployment':{'automatic_windows_update':True}}))
    if phase=='failed':
        (tmp_path/'result.json').write_text('{"status":"failed","message":"Lecture momentanément bloquée"}')
    wrapper=tmp_path/'early.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
& 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
'''.replace('DATA',str(tmp_path)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=15)
    assert run.returncode==0,run.stderr
    assert not (tmp_path/'finalized').exists()
    assert not (tmp_path/'maintenance.json').exists()
    assert not (tmp_path/'progress.json').exists()
