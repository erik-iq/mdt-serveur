"""Reprise de fin sur un nouveau démarrage, sans réinstallation ni succès inventé."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


@pytest.mark.skipif(not PWSH, reason='PowerShell requis')
@pytest.mark.parametrize('case', ['success', 'missing_app', 'active_installer', 'shutdown_failure', 'hp_failure','kb_reboots','wu_reboots'])
def test_final_restart_is_checkpointed_and_success_requires_a_new_boot(tmp_path, case):
    for name in ('Unattend.ps1', 'IQ-Paths.ps1', 'Client-Software.ps1', 'Maintenance.ps1'):
        shutil.copy(ROOT/'scripts'/name, tmp_path/name)
    (tmp_path/'personalization.json').write_text(json.dumps({'settings': {'winget_packages':['vlc','hpia'], 'unattended':True}, 'deployment':{'final_restart':True,'cached_windows_updates':case=='kb_reboots','automatic_windows_update':case=='wu_reboots'}}))
    (tmp_path/'result.json').write_text(json.dumps({'status':'completed','software_status':'completed','restart_needed':False,'applications':[{'id':key,'status':'completed','verification':{'method':'initial'}} for key in ('vlc','hpia')]}))
    (tmp_path/'Updates.ps1').write_text('function Disable-AtelierAutoLogon {}')
    (tmp_path/'HP-ImageAssistant.ps1').write_text('''
function Get-AtelierHpBootIdentity { return $global:boot }
function Invoke-AtelierHpia {
 param($DataPath,$ToolsPath,$OnProgress)
 if (Test-Path (Join-Path $DataPath 'hpia-result.json')) { return Get-Content (Join-Path $DataPath 'hpia-result.json') -Raw|ConvertFrom-Json }
 $value=@{status=$(if ($global:mode -eq 'hp_failure') {'needs_attention'}else{'completed'});reboot_required=$true;exit_code=3010;message='HP';packages=@(@{softpaq_id='sp12345';code=3010})}
 $value|ConvertTo-Json -Depth 8|Set-Content (Join-Path $DataPath 'hpia-result.json')
 return [pscustomobject]$value
}
''',encoding='utf-8-sig')
    (tmp_path/'Reporting.ps1').write_text('''
function Get-AtelierInstalledClientSoftware {
 param($Key)
 Add-Content (Join-Path $DataPath 'verified') $Key
 if ($global:mode -eq 'missing_app' -and $Key -eq 'vlc') { return $null }
 return @{version='2';verification=@{method='after_boot'}}
}
function Complete-AtelierReport { param($DataPath,$ToolsPath);Add-Content (Join-Path $DataPath 'reported') 'yes' }
''')
    (tmp_path/'Client-KBUpdates.ps1').write_text("function Invoke-AtelierCachedWindowsUpdates {param($DataPath,$OnProgress);[pscustomobject]@{status=$(if($global:boot -eq '2026-10-22T08:00:00.0000000Z'){'completed'}else{'reboot_pending'});message='KB';source='server_250';reboot_required=$true}}")
    (tmp_path/'Client-WindowsUpdate.ps1').write_text("function Invoke-AtelierAutomaticWindowsUpdate {param($DataPath,$OnProgress);[pscustomobject]@{status=$(if($global:boot -eq '2026-10-22T08:00:00.0000000Z'){'completed'}else{'reboot_pending'});message='Windows Update';source='windows_update';reboot_required=$true}}")
    script=r'''
$ErrorActionPreference='Stop'
$global:mode='CASE'
$global:boot='2026-10-22T06:00:00.0000000Z'
function Unregister-ScheduledTask { [CmdletBinding()]param($TaskName,[switch]$Confirm) }
function Get-Process { [CmdletBinding()]param($Name);if ($global:mode -eq 'active_installer') { [pscustomobject]@{ProcessName='msiexec'} } }
function Get-LocalUser { [pscustomobject]@{SID=[pscustomobject]@{Value='S-1-5-21-123-500'};Name='Administrateur';Enabled=$true} }
function Set-ItemProperty {param($Path,$Name,$Value)}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force)}
function shutdown.exe {
 param([Parameter(ValueFromRemainingArguments)]$Arguments)
 $checkpoint=Get-Content 'DATA/maintenance.json' -Raw|ConvertFrom-Json
 if ($checkpoint.status -ne 'reboot_pending' -or -not $checkpoint.final_restart.requested_at) { throw 'Point de reprise absent' }
 Add-Content 'DATA/shutdown-count' 'yes'
 $global:LASTEXITCODE=$(if ($global:mode -eq 'shutdown_failure') {1}else{0})
}
& 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
Copy-Item 'DATA/maintenance.json' 'DATA/first.json'
if ($global:mode -notin @('active_installer','shutdown_failure','hp_failure')) {
 & 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
 if (Test-Path 'DATA/reported') {throw 'Rapport terminé avant redémarrage'}
 $global:boot='2026-10-22T07:00:00.0000000Z'
 if ($global:mode -in @('kb_reboots','wu_reboots')) {
  & 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
  if (Test-Path 'DATA/reported') {throw 'Bilan avant la fin des KB'}
  $global:boot='2026-10-22T08:00:00.0000000Z'
 }
 & 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
 & 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
}
'''.replace('DATA',str(tmp_path).replace("'","''")).replace('CASE',case)
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    proc=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=40)
    assert proc.returncode == 0, proc.stderr
    read=lambda name:json.loads((tmp_path/name).read_text(encoding='utf-8-sig'))
    first, final=read('first.json'),read('maintenance.json')
    if case in ('active_installer','shutdown_failure','hp_failure'):
        assert final['status']==('retry_pending' if case=='active_installer' else 'needs_attention')
        assert not (tmp_path/'verified').exists()
    else:
        assert first['status']=='reboot_pending'
        assert (tmp_path/'shutdown-count').read_text().splitlines()==(['yes','yes'] if case in ('kb_reboots','wu_reboots') else ['yes'])
        assert final['reboots']==(2 if case in ('kb_reboots','wu_reboots') else 1) and not final['reboot_required']
        assert final['final_restart']['completed_at']
        assert (tmp_path/'verified').read_text().splitlines()==(['vlc','hpia']*(2 if case in ('kb_reboots','wu_reboots') else 1))
        assert final['status']==('needs_attention' if case=='missing_app' else 'completed')
        assert not read('hpia-result.json')['reboot_required']
        assert read('hpia-result.json')['exit_code']==3010
