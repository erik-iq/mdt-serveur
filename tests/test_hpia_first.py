"""HPIA précède les logiciels et le dossier IQ, sans Windows Update automatique."""
import json
from pathlib import Path

import pytest
from test_software_recovery import setup_client, run_ps, ROOT, PWSH

pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell requis')


@pytest.mark.parametrize('mode',['selected','unchecked','bios_resume','hp_attention','tool_failure'])
def test_hpia_is_first_and_software_waits_for_bios_resume(tmp_path,mode):
    data,_,script=setup_client(tmp_path)
    payload=json.loads((data/'personalization.json').read_text())
    payload['settings']['winget_packages']=['vlc'] if mode=='unchecked' else ['vlc','hpia']
    payload['settings']['unattended']=True
    payload['deployment'].update(hpia_first=True,automatic_windows_update=False,cached_windows_updates=False,allow_bios_restart=True)
    (data/'personalization.json').write_text(json.dumps(payload))
    (data/'Client-Software.ps1').write_text((data/'Client-Software.ps1').read_text('utf-8-sig')+r'''
function Install-AtelierClientSoftware {
 param($DataPath,$Packages,$OnProgress)
 foreach($key in $Packages){
  Add-Content (Join-Path $DataPath 'order') ('prepare.'+$key)
  if($key -eq 'hpia'){
   if($global:mode -eq 'tool_failure'){[pscustomobject]@{id='hpia';status='failed';name='HP';exit_code=1;reason='Fixture';tool=$null}}
   else{[pscustomobject]@{id='hpia';status='completed';name='HP';exit_code=0;tool=@{path='HPImageAssistant.exe'}}}
  }else{[pscustomobject]@{id=$key;status='completed';name=$key;exit_code=3010;verification=@{method='fixture'}}}
 }
}
''',encoding='utf-8-sig')
    (data/'HP-ImageAssistant.ps1').write_text(r'''
function Get-AtelierHpBootIdentity {return '2026-10-23T10:00:00Z'}
function Invoke-AtelierHpia {
 param($DataPath,$ToolsPath,$OnProgress)
 if($global:checkingMaintenance){throw 'La finalisation ne doit pas relancer HPIA'}
 Add-Content (Join-Path $DataPath 'order') 'hp.install'
 $value=[pscustomobject]@{status=$(if($global:mode -eq 'bios_resume' -and -not $global:resumed){'reboot_pending'}elseif($global:mode -eq 'hp_attention'){'needs_attention'}else{'completed'});message='Fixture HP';reboot_required=$false;exit_code=0;resumed_after_reboot=[bool]$global:resumed;boot_id='2026-10-23T09:00:00Z'}
 $value|ConvertTo-Json|Set-Content (Join-Path $DataPath 'hpia-result.json')
 return $value
}
function Request-AtelierHpBiosRestart {param($DataPath);Add-Content (Join-Path $DataPath 'order') 'hp.reboot'}
''',encoding='utf-8-sig')
    (data/'Prepare-IQTools.ps1').write_text("param($DataPath);Add-Content (Join-Path $DataPath 'order') 'iq'")
    (data/'WindowsUpdate-First.ps1').write_text("throw 'Windows Update ne doit pas être lancé'")
    (data/'Reporting.ps1').write_text('''
function Initialize-AtelierReportTrust {}
function Send-AtelierWindowsProgress {}
function Complete-AtelierReport {}
''')
    script+=r'''
$global:mode='MODE';$global:resumed=$false;$global:checkingMaintenance=$false
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);[pscustomobject]@{Manufacturer='HP';LastBootUpTime=[datetime]'2026-10-23T10:00:00Z'}}
function Get-LocalUser {[pscustomobject]@{Name='Administrateur';SID=[pscustomobject]@{Value='S-1-5-21-123-500'};Enabled=$true}}
function Set-ItemProperty {param($Path,$Name,$Value);if($Name -eq 'AutoAdminLogon'){Add-Content 'DATA/order' 'hp.autologon'}}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force)}
& 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
if($global:mode -eq 'bios_resume'){
 if(Test-Path 'DATA/result.json'){throw 'Logiciels terminés avant la reprise BIOS'}
 if((Get-Content 'DATA/order' -Raw) -match 'prepare.vlc|iq'){throw 'Logiciels ou dossier IQ lancés avant la reprise BIOS'}
 $global:resumed=$true
 & 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
}
$global:checkingMaintenance=$true
& 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
'''.replace('DATA',str(data)).replace('MODE',mode)
    run_ps(tmp_path,script)
    order=(data/'order').read_text('utf-8-sig').splitlines()
    assert order.index('prepare.vlc')<order.index('iq')
    if mode=='unchecked':
        assert not any(item.startswith('hp.') or item=='prepare.hpia' for item in order)
    elif mode=='tool_failure':
        assert order.index('prepare.hpia')<order.index('prepare.vlc') and 'hp.install' not in order
    else:
        assert order.index('prepare.hpia')<order.index('hp.autologon')<order.index('hp.install')<order.index('prepare.vlc')
        assert order.count('hp.install')==(2 if mode=='bios_resume' else 1)
        if mode=='bios_resume':
            assert order.index('hp.reboot')<order.index('prepare.vlc')
    result=json.loads((data/'result.json').read_text('utf-8-sig'))
    assert result['restart_needed'] is True
    maintenance=json.loads((data/'maintenance.json').read_text('utf-8-sig'))
    assert maintenance['windows']['status']=='manual' and maintenance['store']['status']=='manual'
    if mode in ('tool_failure','hp_attention'):
        assert maintenance['status']=='needs_attention'


def test_new_deployments_disable_both_update_paths_and_include_hp_first_module():
    deploy=(ROOT/'scripts/Deploy.ps1').read_text('utf-8-sig')
    assert 'automatic_windows_update=$false;hpia_first=$true;' in deploy
    assert 'cached_windows_updates=$true;kb_first=$true;' in deploy
    for name in ('Deploy.ps1','Build-WinPE.ps1'):
        assert "'Client-HpiaFirst.ps1'" in (ROOT/'scripts'/name).read_text('utf-8-sig')


def test_captured_windows_update_task_disables_itself_for_new_payload(tmp_path):
    data,_,script=setup_client(tmp_path)
    payload=json.loads((data/'personalization.json').read_text())
    payload['deployment'].update(hpia_first=True,automatic_windows_update=False,cached_windows_updates=False)
    (data/'personalization.json').write_text(json.dumps(payload))
    (data/'Client-WindowsUpdate.ps1').write_text("function Invoke-AtelierAutomaticWindowsUpdate {throw 'Windows Update ne doit pas démarrer'}")
    script+=r'''
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm);Set-Content 'DATA/unregistered' $TaskName}
. 'DATA/WindowsUpdate-First.ps1' -DataPath 'DATA'
Invoke-AtelierWindowsUpdateFirstWorker -DataPath 'DATA'
'''.replace('DATA',str(data))
    run_ps(tmp_path,script)
    assert (data/'unregistered').read_text().strip()=='AtelierPXE-WindowsUpdateFirst'
    assert not (data/'windows-update-result.json').exists()
    assert not (data/'progress.json').exists()
