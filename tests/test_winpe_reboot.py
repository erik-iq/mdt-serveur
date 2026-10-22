"""Reboot requests must follow verified staging and stay inside WinPE."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['staged','not_staged','not_winpe','native_failure'])
def test_staged_only_reboot_checks_native_exit_and_keeps_failure_visible(tmp_path,case):
    script=tmp_path/'run.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
$script:slept=0;$script:reboots=0
function Test-Path {param($Path);if($Path -ne 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){throw 'Unexpected check'};return ('CASE' -ne 'not_winpe')}
function Start-Sleep {param($Seconds);$script:slept=$Seconds}
function wpeutil.exe {
 param($Action)
 if($Action -ne 'reboot'){throw 'Unexpected opération'}
 $script:reboots++;$global:LASTEXITCODE=$(if('CASE' -eq 'native_failure'){5}else{0})
}
$failed=$false;$message=''
try {Restart-AtelierStagedWindows -Staged:('CASE' -ne 'not_staged')} catch {$failed=$true;$message=$_.Exception.Message}
@{failed=$failed;message=$message;slept=$script:slept;reboots=$script:reboots}|ConvertTo-Json -Compress
'''.replace('LIBRARY',str(ROOT/'scripts/WinPE-Session.ps1')).replace('CASE',case))
    run=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=20)
    assert run.returncode==0,run.stdout+run.stderr
    result=json.loads(run.stdout.splitlines()[-1])
    requested=case in {'staged','native_failure'}
    assert result['reboots']==int(requested)
    assert result['slept']==(5 if requested else 0)
    assert result['failed']==(case in {'not_winpe','native_failure'})
    if case=='native_failure':assert 'code 5' in result['message']


@pytest.mark.parametrize('case',['success','changed_answer','changed_backup','server_failure','reboot_failure'])
def test_real_final_staging_checks_and_cleanup_precede_reboot(tmp_path,case):
    """Exécute the agent's final staging/catch/finally, excluding disk opérations."""
    script=tmp_path/'finish.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/Unattend.ps1'
. 'PROJECT/scripts/WinPE-Session.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile('PROJECT/scripts/Deploy.ps1',[ref]$null,[ref]$null)
$core=$ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text -match 'Assert-Active' } | Select-Object -First 1
$index=-1
for ($i=0;$i -lt $core.Body.Statements.Count;$i++) { if($core.Body.Statements[$i].Extent.Text -eq 'Assert-Active'){$index=$i} }
if($index -lt 0){throw 'Final deployment checks missing'}
$tail=($core.Body.Statements | Select-Object -Skip $index | ForEach-Object {$_.Extent.Text}) -join "`n"
$send=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Send-Event'},$true)
Invoke-Expression $send.Extent.Text
$global:atelierReleased=$false;$global:atelierDisposed=$false
$mutex=[pscustomobject]@{}
$mutex | Add-Member ScriptMethod ReleaseMutex {$global:atelierReleased=$true}
$mutex | Add-Member ScriptMethod Dispose {$global:atelierDisposed=$true}
$ownsMutex=$true;$started=$true;$staged=$false;$imageTiming=$null;$imageLock=$null
$headers=@{Authorization='Bearer fixture-token'};$Token='fixture-token';$lastProgress=0;$endpoint='https://atelier.test/agent/fixture'
$xml=New-AtelierUnattend -Plan ([pscustomobject]@{hostname='PC-TEST';locale='fr-FR'})
$answer=Write-AtelierVerifiedUtf8File -Path 'WORK/answer.xml' -Content $xml -Unattend
$answerBackup=Write-AtelierVerifiedUtf8File -Path 'WORK/backup.xml' -Content $xml -Unattend
if('CASE' -eq 'changed_answer'){Add-Content $answer.path 'tampered'}
if('CASE' -eq 'changed_backup'){Add-Content $answerBackup.path 'tampered'}
function Assert-Active {}
function Test-Path {param($Path);return ($Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')}
function Start-Sleep {param($Seconds);if($Seconds -ne 5){throw 'Unexpected delay'}}
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body)
 $event=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
 if($event.status -eq 'staged' -and 'CASE' -eq 'server_failure'){throw 'Server did not confirm staging'}
 Add-Content 'WORK/events' $event.status
}
function wpeutil.exe {
 param($Action)
 if($Action -ne 'reboot' -or -not $global:atelierReleased -or -not $global:atelierDisposed -or $headers.Count -ne 0 -or $Token){throw 'Reboot before cleanup'}
 Set-Content 'WORK/reboot-requested' 'yes'
 $global:LASTEXITCODE=$(if('CASE' -eq 'reboot_failure'){5}else{0})
}
$finish='try {'+"`n"+$tail+"`n}"+($core.CatchClauses | ForEach-Object {$_.Extent.Text})+' finally '+$core.Finally.Extent.Text+"`n"+$ast.EndBlock.Statements[-1].Extent.Text
Invoke-Expression $finish
'''.replace('PROJECT',str(ROOT)).replace('WORK',str(tmp_path)).replace('CASE',case))
    run=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=25)
    assert run.returncode==(0 if case=='success' else 1),run.stdout+run.stderr
    assert (tmp_path/'reboot-requested').exists()==(case in {'success','reboot_failure'}),run.stdout+run.stderr
    assert (tmp_path/'events').read_text(encoding='utf-8-sig').splitlines()==(['staged'] if case in {'success','reboot_failure'} else ['failed'])
