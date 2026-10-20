"""Run specialize account setup against a synthetic local-account registry."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['disabled','already_enabled','french','collision','missing','activation_failed','interactive'])
def test_builtin_account_by_sid_activation_is_verified_without_creating_an_account(tmp_path,case):
    data=tmp_path/'AtelierPXE';data.mkdir()
    (data/'personalization.json').write_text(json.dumps({'settings':{'unattended':case!='interactive'}}))
    source=(ROOT/'scripts/Prepare-Windows.ps1').read_text().replace('#requires -RunAsAdministrator\n','')
    (tmp_path/'Prepare-Windows.ps1').write_text(source)
    script=tmp_path/'run.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
$env:ProgramData='WORK'
$global:atelierFixtureProperties=@{};$global:atelierFixtureChanged=0
$global:atelierFixtureUser=[pscustomobject]@{Name=$(if('CASE' -eq 'french'){'Administrateur'}else{'Administrator'});SID=[pscustomobject]@{Value='S-1-5-21-1-500'};Enabled=('CASE' -eq 'already_enabled')}
function New-Item {param($Path,[switch]$Force)}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force);$global:atelierFixtureProperties[$Name]=$Value}
function Get-ItemProperty {param($Path,$Name);return @{HiberbootEnabled=$global:atelierFixtureProperties.HiberbootEnabled}}
function Get-LocalUser {
 [CmdletBinding()]param($Name,$SID)
 if ('CASE' -eq 'missing') { return }
 if ($Name) {
  if ('CASE' -eq 'collision') { return [pscustomobject]@{SID=[pscustomobject]@{Value='S-1-5-21-1-1001'}} }
  if ($global:atelierFixtureUser.Name -eq $Name) { return $global:atelierFixtureUser };return
 }
 if ($SID -and $SID.Value -ne 'S-1-5-21-1-500') { throw 'Wrong account' }
 return $global:atelierFixtureUser
}
function Rename-LocalUser {param($SID,$NewName);$global:atelierFixtureUser.Name=$NewName;$global:atelierFixtureChanged++}
function Set-LocalUser {param($SID,$Password,$PasswordNeverExpires);if($Password.Length -ne 0){throw 'Unexpected password'};$global:atelierFixtureChanged++}
function Enable-LocalUser {param($SID);if('CASE' -ne 'activation_failed'){$global:atelierFixtureUser.Enabled=$true};$global:atelierFixtureChanged++}
function New-LocalUser { throw 'Must not create or replace an account' }
$failed=$false
try { & 'WORK/Prepare-Windows.ps1' } catch { $failed=$true;$message=$_.Exception.Message }
@{failed=$failed;message=$message;enabled=$global:atelierFixtureUser.Enabled;name=$global:atelierFixtureUser.Name;changed=$global:atelierFixtureChanged;properties=$global:atelierFixtureProperties}|ConvertTo-Json -Depth 4 -Compress
'''.replace('WORK',str(tmp_path)).replace('CASE',case))
    run=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=25)
    assert run.returncode==0,run.stdout+run.stderr
    result=json.loads(run.stdout.splitlines()[-1])
    assert result['failed']==(case in {'collision','missing','activation_failed'}),result
    assert result['properties']['HiberbootEnabled']==0
    if case=='interactive':assert result['changed']==0
    elif not result['failed']:
        assert result['enabled'] and result['name']=='Administrateur'
        assert result['properties']['EnableLUA']==result['properties']['FilterAdministratorToken']==result['properties']['LimitBlankPasswordUse']==1
