"""KB du serveur avant HPIA et logiciels, suivi visible dès la connexion Windows."""
import hashlib
import json
from pathlib import Path

import pytest
from test_software_recovery import setup_client, run_ps, ROOT, PWSH

pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell requis')


@pytest.mark.parametrize('mode',['ready','queued','reboot','failed'])
def test_kb_first_precedes_hp_and_software_and_resumes_after_restart(tmp_path,mode):
    data,exe,script=setup_client(tmp_path)
    payload=json.loads((data/'personalization.json').read_text())
    payload['settings'].update(unattended=True,winget_packages=['hpia','vlc'])
    payload['deployment'].update(cached_windows_updates=True,kb_first=True,hpia_first=True,automatic_windows_update=False)
    (data/'personalization.json').write_text(json.dumps(payload))
    (data/'Client-KBUpdates.ps1').write_text(r'''
function Get-AtelierKbBoot {return $global:boot}
function Invoke-AtelierCachedWindowsUpdates {
 param($DataPath,$OnProgress)
 if($global:checkingMaintenance){throw 'Les KB ne doivent pas être réinstallées en finalisation'}
 Add-Content (Join-Path $DataPath 'order') 'kb'
 $kb=[pscustomobject]@{source='server_250';status=$(if(-not $global:resumed -and $global:mode -eq 'reboot'){'reboot_pending'}elseif(-not $global:resumed -and $global:mode -eq 'queued'){'retry_pending'}elseif($global:mode -eq 'failed'){'needs_attention'}else{'completed'});message='Fixture KB';reboot_required=$false;entries=@()}
 $kb|ConvertTo-Json|Set-Content (Join-Path $DataPath 'windows-kb-result.json')
 return $kb
}
''')
    (data/'Client-HpiaFirst.ps1').write_text(r'''
function Invoke-AtelierHpiaFirst {
 param($DataPath,$ToolsPath,$OnProgress)
 Add-Content (Join-Path $DataPath 'order') 'hp'
 $hp=[pscustomobject]@{status='completed';reboot_required=$false;message='HP fixture'}
 $hp|ConvertTo-Json|Set-Content (Join-Path $DataPath 'hpia-result.json')
 [pscustomobject]@{pending=$false;hp=$hp;application=@{id='hpia';name='HP';status='completed';exit_code=0;tool=@{path='HPImageAssistant.exe'}}}
}
''')
    (data/'Prepare-IQTools.ps1').write_text("param($DataPath);Add-Content (Join-Path $DataPath 'order') 'iq'")
    (data/'Reporting.ps1').write_text('''
function Initialize-AtelierReportTrust {param($DataPath);if(-not (Test-Path (Join-Path $DataPath 'ui'))){throw 'Réseau avant la fenêtre'}}
function Send-AtelierWindowsProgress {param($DataPath,$Status,$Percent,$Message);if(-not (Test-Path (Join-Path $DataPath 'ui'))){throw 'Réseau avant la fenêtre'}}
function Complete-AtelierReport {}
''')
    script+=r'''
$global:mode='MODE';$global:boot='boot1';$global:resumed=$false;$global:checkingMaintenance=$false
function Get-LocalUser {[pscustomobject]@{Name='Administrateur';SID=[pscustomobject]@{Value='S-1-5-21-123-500'};Enabled=$true}}
function Set-ItemProperty {param($Path,$Name,$Value)}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force)}
function Start-Process {Set-Content 'DATA/ui' 'yes'}
function Get-Process {param($Name);if($Name -eq 'explorer'){if(-not (Test-Path 'DATA/ui')){throw "Fenêtre absente pendant l’attente du bureau"};[pscustomobject]@{Id=123}}}
function shutdown.exe {
 param([Parameter(ValueFromRemainingArguments)]$Arguments)
 if(-not (Test-Path 'DATA/kb-first-restart.json')){throw 'Point de reprise absent'}
 if(Test-Path 'EXE.calls'){throw 'Logiciel démarré avant redémarrage KB'}
 Add-Content 'DATA/order' 'reboot';$global:LASTEXITCODE=0
}
& 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
if($global:mode -in @('queued','reboot')){
 if(Test-Path 'EXE.calls'){throw 'Logiciel lancé avant la fin des KB'}
 if(Test-Path 'DATA/result.json'){throw 'Préparation finie avant les KB'}
 if((Get-Content 'DATA/order' -Raw) -match 'hp|iq'){throw 'HPIA ou IQ lancé avant les KB'}
 if($global:mode -eq 'reboot'){
  & 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
 }
 $global:boot='boot2';$global:resumed=$true
 & 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
}
$global:checkingMaintenance=$true
& 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
'''.replace('DATA',str(data)).replace('EXE',str(exe)).replace('MODE',mode)
    run_ps(tmp_path,script)
    order=(data/'order').read_text().splitlines()
    assert order.index('kb')<order.index('hp')<order.index('iq')
    assert order.count('hp')==1
    assert Path(str(exe)+'.calls').read_text().splitlines()==['install']
    if mode=='reboot':assert order.count('reboot')==1
    state=json.loads((data/'maintenance.json').read_text('utf-8-sig'))
    assert state['windows']['source']=='server_250'
    assert state['windows']['status']==('needs_attention' if mode=='failed' else 'completed')
    if mode=='failed':assert state['status']=='needs_attention'


def test_first_logon_command_opens_progress_before_registering_and_starting_work(tmp_path):
    data,_,script=setup_client(tmp_path)
    source=(data/'Start-Preparation.ps1').read_text('utf-8-sig').replace('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value',"'S-1-5-21-123-500'")
    (data/'Start-Preparation.ps1').write_text(source,'utf-8-sig')
    script+=r'''
function Start-Process {if(-not (Test-Path 'DATA/progress.json')){throw 'État initial absent'};Add-Content 'DATA/order' 'ui'}
function Register-ScheduledTask {Add-Content 'DATA/order' 'register'}
function Start-ScheduledTask {Add-Content 'DATA/order' 'start'}
& 'DATA/Start-Preparation.ps1' -DataPath 'DATA'
'''.replace('DATA',str(data))
    run_ps(tmp_path,script)
    assert (data/'order').read_text().splitlines()==['ui','register','start']


def test_new_payload_disables_server_cache_and_retains_legacy_helper():
    source=(ROOT/'scripts/Deploy.ps1').read_text('utf-8-sig')
    assert 'cached_windows_updates=$false;kb_first=$false;automatic_windows_update=$false;' in source
    for name in ('Deploy.ps1','Build-WinPE.ps1'):
        assert "'Client-KBFirst.ps1'" in (ROOT/'scripts'/name).read_text('utf-8-sig')


def test_theme_and_wallpaper_publish_progress_while_initial_window_is_open(tmp_path):
    data,exe,script=setup_client(tmp_path)
    resource=data/'Resources';resource.mkdir()
    image=b'Fond de test, rendu natif remplace par une fixture'
    (resource/'Fond.png').write_bytes(image)
    payload=json.loads((data/'personalization.json').read_text())
    payload['settings']['theme']='dark'
    payload['wallpaper']={'filename':'Fond.png','sha256':hashlib.sha256(image).hexdigest()}
    (data/'personalization.json').write_text(json.dumps(payload))
    source=(data/'FirstLogon.ps1').read_text('utf-8-sig')
    source=source.replace('[AtelierWallpaper]::SystemParametersInfo(20,0,$wallpaper,3)','(Invoke-FixtureWallpaper $wallpaper)')
    (data/'FirstLogon.ps1').write_text(source,'utf-8-sig')
    (data/'Prepare-IQTools.ps1').write_text("param($DataPath);Add-Content (Join-Path $DataPath 'order') 'iq'")
    (data/'Reporting.ps1').write_text('''
function Initialize-AtelierReportTrust {param($DataPath);if(-not (Test-Path (Join-Path $DataPath 'ui'))){throw 'Réseau avant la fenêtre'}}
function Send-AtelierWindowsProgress {param($DataPath,$Status,$Percent,$Message);if(-not (Test-Path (Join-Path $DataPath 'ui'))){throw 'Réseau avant la fenêtre'}}
function Complete-AtelierReport {}
''')
    script+=r'''
$env:SystemDrive='DRIVE'
function Start-Process {Set-Content 'DATA/ui' 'yes';Add-Content 'DATA/order' 'ui'}
function New-Item {
 [CmdletBinding()]param($Path,$ItemType,[switch]$Force)
 if($Path -like 'HKCU:*'){return [pscustomobject]@{Path=$Path}}
 Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function New-ItemProperty {
 param($Path,$Name,$Value,$PropertyType,[switch]$Force)
 $progress=Get-Content 'DATA/progress.json' -Raw|ConvertFrom-Json
 if($progress.message -notmatch 'thème'){throw 'Progression du thème absente'}
 if(-not (Test-Path 'EXE.calls')){throw 'Thème appliqué avant les logiciels'}
 if(-not (Test-Path 'DATA/ui')){throw 'Fenêtre de progression absente'}
 Add-Content 'DATA/order' 'theme'
}
function Set-ItemProperty {
 param($Path,$Name,$Value)
 $progress=Get-Content 'DATA/progress.json' -Raw|ConvertFrom-Json
 if($progress.message -notmatch 'fond'){throw 'Progression du fond absente'}
}
function Invoke-FixtureWallpaper {
 param($Path)
 if(-not (Test-Path $Path)){throw 'Fond non copié'}
 Add-Content 'DATA/order' 'wallpaper'
 return $true
}
& 'DATA/FirstLogon.ps1' -DataPath 'DATA' -ToolsPath 'DATA/IQ_'
'''.replace('DATA',str(data)).replace('EXE',str(exe)).replace('DRIVE',str(tmp_path))
    run_ps(tmp_path,script)
    order=(data/'order').read_text().splitlines()
    assert order.index('ui')<order.index('theme')<order.index('wallpaper')<order.index('iq')
