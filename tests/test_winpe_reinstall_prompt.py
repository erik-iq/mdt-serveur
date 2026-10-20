"""Exercise PowerShell 5.1-compatible conflict parsing and the real connection flow."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')
ID='12345678-1234-1234-1234-123456789abc'
PRELUDE=r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/WinPE-Session.ps1'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
public class AtelierConflictFixture : WebResponse {
 public HttpStatusCode StatusCode { get; set; }
 public string Body;
 public override Stream GetResponseStream() {return new MemoryStream(Encoding.UTF8.GetBytes(Body));}
}
'@
function New-ConflictFixture {
 param([string]$Body,[int]$Code=409,[switch]$StreamOnly)
 $reply=New-Object AtelierConflictFixture
 $reply.StatusCode=[Net.HttpStatusCode]$Code;$reply.Body=$Body
 $web=New-Object Net.WebException('HTTP error',$null,[Net.WebExceptionStatus]::ProtocolError,$reply)
 $record=New-Object Management.Automation.ErrorRecord($web,'Fixture',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
 if (-not $StreamOnly) { $record.ErrorDetails=New-Object Management.Automation.ErrorDetails($Body) }
 return $record
}
'''


def execute(tmp_path,source):
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text((PRELUDE+source).replace('PROJECT',str(ROOT)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=25)
    assert run.returncode==0,run.stdout+run.stderr
    return json.loads(run.stdout.splitlines()[-1])


@pytest.mark.parametrize('case',['valid','stream','generic_error_details','wrong_serial','bare_409','other_conflict','invalid_json','invalid_uuid','oversize','not_409'])
def test_only_specific_bounded_server_response_enables_reinstall(tmp_path,case):
    detail={'code':'windows_prepared','serial_number':'HP-1234','deployment_id':ID}
    if case=='wrong_serial':detail['serial_number']='HP-OTHER'
    if case=='invalid_uuid':detail['deployment_id']='not-an-id'
    if case=='other_conflict':detail['code']='already_running'
    body=json.dumps({'detail':detail})
    if case=='bare_409':body='409 Conflict'
    if case=='invalid_json':body='{broken'
    if case=='oversize':body=body+' '*5000
    (tmp_path/'reply.json').write_text(body)
    result=execute(tmp_path,r'''
$failure=New-ConflictFixture -Body ([IO.File]::ReadAllText('WORK/reply.json')) -Code CODE -StreamOnly:$STREAM
if ('CASE' -eq 'generic_error_details') { $failure.ErrorDetails=New-Object Management.Automation.ErrorDetails('The remote server returned an error: (409) Conflict.') }
$prepared=Get-AtelierPreparedWindowsConflict -Failure $failure -SerialNumber 'HP-1234'
@{prepared=$prepared}|ConvertTo-Json -Depth 3 -Compress
'''.replace('WORK',str(tmp_path)).replace('CODE','500' if case=='not_409' else '409').replace('$STREAM','$true' if case=='stream' else '$false').replace('CASE',case))
    assert bool(result['prepared'])==(case in {'valid','stream','generic_error_details'}),result
    if result['prepared']:assert result['prepared']['deployment_id']==ID


@pytest.mark.parametrize('case',['yes','no','other_error'])
def test_real_connect_prompts_once_and_retries_only_after_yes(tmp_path,case):
    result=execute(tmp_path,r'''
$ast=[Management.Automation.Language.Parser]::ParseFile('PROJECT/scripts/Wizard.ps1',[ref]$null,[ref]$null)
$connect=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Connect-Post'},$true)
Invoke-Expression $connect.Extent.Text
$Config=@{internal_mode=$true;auto_enroll=$true;boot_release='ATELIER-4'}
$script:root='https://atelier.test';$script:share='\\atelier.test\AtelierImages';$script:controls=@{}
$script:status=[pscustomobject]@{Text=''};$script:next=[pscustomobject]@{Enabled=$false};$script:proposedName='1234'
$script:page=0;$script:calls=0;$script:prompts=0;$script:mapped=$false
$form=[pscustomobject]@{};$form | Add-Member ScriptMethod Refresh {}
function Get-AtelierHardwareSerial {return 'HP-1234'}
function Get-AtelierWinPENetwork {return [pscustomobject]@{macs=@()}}
function Confirm-PreparedWindowsReinstall {$script:prompts++;return ('CASE' -eq 'yes')}
function Send-Json {
 param($Path,$Body,$Authenticated)
 $script:calls++
 if ($script:calls -eq 1) {
  $code=if('CASE' -eq 'other_error'){'already_running'}else{'windows_prepared'}
  $json=@{detail=@{code=$code;serial_number='HP-1234';deployment_id='IDENTIFIER'}} | ConvertTo-Json -Compress
  throw (New-ConflictFixture -Body $json)
 }
 if ($Body.reinstall_deployment_id -ne 'IDENTIFIER' -or $Body.serial_number -ne 'HP-1234') {throw 'Wrong retry'}
 return [pscustomobject]@{id='new-job';agent_token='fixture-token';plan=[pscustomobject]@{profile_id='profile'}}
}
function Invoke-RestMethod {param($Uri,$Headers,$TimeoutSec);return @{username='fixture';password='fixture-password'}}
function Get-PSDrive {param($Name,$ErrorAction)}
function New-PSDrive {param($Name,$PSProvider,$Root,$Credential,[switch]$Persist,$Scope);$script:mapped=$true}
function Set-Profile {param($Id)}
function Show-Page {}
$failed=$false
try {Connect-Post} catch {$failed=$true}
@{calls=$script:calls;prompts=$script:prompts;page=$script:page;mapped=$script:mapped;failed=$failed}|ConvertTo-Json -Compress
'''.replace('CASE',case).replace('IDENTIFIER',ID))
    assert result['failed']==(case=='other_error'),result
    assert result['calls']==(2 if case=='yes' else 1)
    assert result['prompts']==(0 if case=='other_error' else 1)
    assert result['mapped']==(case=='yes') and result['page']==(1 if case=='yes' else 0)
