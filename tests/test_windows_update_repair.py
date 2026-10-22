"""Réparation locale sans déploiement, sans arrêter un installateur ni perdre les checkpoints."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell requis')


@pytest.mark.parametrize('mode',['resume','completed','task_active','installer_busy'])
def test_repair_keeps_update_and_hp_evidence_then_relaunches_existing_preparation(tmp_path,mode):
    source=tmp_path/'source';source.mkdir()
    data=tmp_path/'data';data.mkdir()
    for path in (ROOT/'scripts').glob('*.ps1'):
        shutil.copy(path,source/path.name)
    repair=(source/'Repair-WindowsUpdate.ps1').read_text('utf-8-sig')
    # La seule identité Windows native devient le SID de la session simulée.
    repair=repair.replace('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value',"'S-1-5-21-123-500'")
    (source/'Repair-WindowsUpdate.ps1').write_text(repair,'utf-8-sig')
    for path in source.glob('*.ps1'):
        shutil.copy(path,data/path.name)
    (data/'personalization.json').write_text(json.dumps({'deployment':{'automatic_windows_update':True}}))
    state={'source':'windows_update','status':'completed' if mode=='completed' else 'needs_attention','message':'Fichier utilisé par un autre processus','passes':[{'updates':[{'status':'installed','title':'Intel déjà installé','result_code':2}]}],'active_pass':{'updates':[{'status':'installing','title':'Résultat à retrouver','result_code':None}]},'attempts':2}
    (data/'windows-update-result.json').write_text(json.dumps(state))
    (data/'maintenance.json').write_text('{"status":"needs_attention"}')
    hp=b'{"status":"completed","packages":[{"softpaq_id":"sp12345","code":3010}]}'
    (data/'hpia-result.json').write_bytes(hp)
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop';$global:mode='MODE'
$env:SystemRoot='DATA'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec)
 if($ClassName -eq 'Win32_OperatingSystem'){[pscustomobject]@{ProductType=1}}
 elseif($global:mode -eq 'resume'){
  [pscustomobject]@{Name='powershell.exe';CommandLine='powershell.exe -File "DATA/Progress.ps1"';ProcessId=701}
  [pscustomobject]@{Name='wuauclt.exe';CommandLine='wuauclt.exe';ProcessId=702}
 }
}
function Stop-Process {param($Id,[switch]$Force);Add-Content 'DATA/stopped' $Id}
function Get-ScheduledTask {[CmdletBinding()]param($TaskName);[pscustomobject]@{TaskName=$TaskName;State=$(if($global:mode -eq 'task_active'){'Running'}else{'Ready'})}}
function New-Object {
 [CmdletBinding()]param([Parameter(Position=0)]$TypeName,[Parameter(Position=1)]$ArgumentList,$ComObject)
 if($ComObject){
  $session=New-Object -TypeName psobject
  $session|Add-Member ScriptMethod CreateUpdateInstaller {[pscustomobject]@{IsBusy=($global:mode -eq 'installer_busy')}}
  return $session
 }
 Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}
function Disable-ScheduledTask {param($TaskName);Add-Content 'DATA/disabled' $TaskName}
function Enable-ScheduledTask {[CmdletBinding()]param($TaskName);Add-Content 'DATA/enabled' $TaskName}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm);Add-Content 'DATA/unregistered' $TaskName}
function New-ScheduledTaskAction {param($Execute,$Argument);@{Argument=$Argument}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);@{}}
function New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User,[switch]$Once,$At);@{}}
function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries);@{}}
function Register-ScheduledTask {param($TaskName,$Action,$Principal,$Trigger,$Settings,[switch]$Force);Set-Content 'DATA/action' $Action.Argument}
function Start-ScheduledTask {param($TaskName);Set-Content 'DATA/started' $TaskName}
try {& 'SOURCE/Repair-WindowsUpdate.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'}
catch {Set-Content 'DATA/error' $_.Exception.Message}
'''.replace('MODE',mode).replace('SOURCE',str(source)).replace('DATA',str(data)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],text=True,capture_output=True,timeout=15)
    assert run.returncode==0,run.stderr
    final=json.loads((data/'windows-update-result.json').read_text('utf-8-sig'))
    assert final['passes']==state['passes'] and final['active_pass']==state['active_pass']
    assert (data/'hpia-result.json').read_bytes()==hp
    if mode in ('task_active','installer_busy'):
        assert (data/'error').exists()
        assert not (data/'started').exists()
        assert not (data/'disabled').exists()
        assert final==state
    else:
        assert not (data/'error').exists(),(data/'error').read_text() if (data/'error').exists() else run.stdout
        assert final['status']==('completed' if mode=='completed' else 'running')
        assert (data/'started').read_text().strip()=='AtelierPXE-Preparation'
        assert 'FirstLogon.ps1' in (data/'action').read_text()
        assert not (data/'maintenance.json').exists()
        assert list((data/'repair-backups').glob('windows-update-*/windows-update-result.json'))

        if mode=='resume':
            assert (data/'stopped').read_text().splitlines()==['701']
