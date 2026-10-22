"""Exercise connection stages and native exception reporting without WinForms."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def run_ps(tmp_path,source):
    script=tmp_path/'run.ps1'
    script.write_text(source.replace('LIBRARY',str(ROOT/'scripts'/'WinPE-Session.ps1'))
                      .replace('WIZARD',str(ROOT/'scripts'/'Wizard.ps1')),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=25)
    assert result.returncode==0,result.stdout+result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize('status',['ConnectFailure','TrustFailure','SecureChannelFailure','Timeout','NameResolutionFailure'])
def test_native_transport_cause_is_preserved_without_guessing_or_exposing_secrets(tmp_path,status):
    message=run_ps(tmp_path,r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
$socket=New-Object Net.Sockets.SocketException(10061)
$web=New-Object Net.WebException('secret-in-message',$socket,[Net.WebExceptionStatus]::STATUS,$null)
$outer=New-Object Exception('secret-in-outer',$web)
$errorRecord=New-Object Management.Automation.ErrorRecord($outer,'secret-in-error-id',[Management.Automation.ErrorCategory]::ConnectionError,'secret-in-target')
Get-AtelierConnectionFailure -Failure $errorRecord -Stage 'API Atelier' -ServerUrl 'https://operator:secret@192.168.99.250/private?token=secret' | ConvertTo-Json -Compress
'''.replace('STATUS',status))
    assert status in message
    assert 'ConnectionRefused' in message
    assert 'https://192.168.99.250' in message
    assert 'secret' not in message and 'operator' not in message and 'private' not in message
    assert 'pilote' not in message and 'MAC' not in message
    if status in {'TrustFailure','SecureChannelFailure'}:assert 'TLS' in message


@pytest.mark.parametrize('case',['success','api','credentials','share'])
def test_real_connect_function_reports_correct_failed_step_with_empty_mac_list(tmp_path,case):
    result=run_ps(tmp_path,r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('WIZARD',[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Connect-Post'},$true)
Invoke-Expression $function.Extent.Text
$Config=@{internal_mode=$true;boot_release='ATELIER-4'}
$script:root='https://192.168.99.250';$script:share='\\192.168.99.250\AtelierImages'
$script:controls=@{};$script:status=[pscustomobject]@{Text=''};$script:proposedName='1234'
$script:page=0;$script:mapped=$false
$form=[pscustomobject]@{};$form | Add-Member ScriptMethod Refresh {}
function Get-AtelierHardwareSerial { return 'HP-SN1234' }
function Get-AtelierWinPENetwork { return [pscustomobject]@{macs=@();message='Inventory unavailable'} }
function Send-Json {
 param($Path,$Body,$Authenticated)
 if ($Body.serial_number -ne 'HP-SN1234' -or $Body.macs.Count -ne 0) { throw 'Invalid identity' }
 if ('CASE' -eq 'api') { throw (New-Object Net.WebException('Cannot connect',[Net.WebExceptionStatus]::ConnectFailure)) }
 return [pscustomobject]@{id='fixture';agent_token='private-token';plan=[pscustomobject]@{profile_id='profile'}}
}
function Invoke-RestMethod {
 param($Uri,$Headers,$TimeoutSec)
 if ($TimeoutSec -ne 20) { throw 'Missing timeout' }
 if ('CASE' -eq 'credentials') { throw 'Share credential retrieval failed' }
 return [pscustomobject]@{username='fixture-user';password='fixture-password'}
}
function Get-PSDrive { param($Name,$ErrorAction) return }
function New-PSDrive {
 param($Name,$PSProvider,$Root,$Credential,[switch]$Persist,$Scope)
 if ('CASE' -eq 'share') { throw 'Share mapping failed' }
 $script:mapped=$true
}
function Set-Profile { param($Id) }
function Show-Page {}
$failed=$false
try { Connect-Post } catch { $failed=$true }
@{failed=$failed;stage=$script:connectionStage;page=$script:page;mapped=$script:mapped} | ConvertTo-Json -Compress
'''.replace('CASE',case))
    assert result['failed']==(case!='success'),result
    assert result['page']==(1 if case=='success' else 0)
    assert result['mapped']==(case=='success')
    assert result['stage']=={'success':'Chargement des profils Windows',
                             "api":"Connexion à l'API Atelier /api/boot/discover",
                             'credentials':'Récupération des accès au partage',
                             'share':'Ouverture du partage des images'}[case]
