"""Software bundle presets are checkbox shortcuts, never implicit installation rules."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

from app.customization import Personalization,SOFTWARE_PRESETS
from test_api import auth,prepare,system

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
COMMON=['vlc','reader','chrome','anydesk']


def test_presets_and_defaults_keep_vendor_tools_explicit():
    assert Personalization().winget_packages==COMMON
    presets={p['id']:p['packages'] for p in SOFTWARE_PRESETS}
    assert presets=={'hp':COMMON+['hpia'],'lenovo':COMMON+['lenovo_system_update']}


@pytest.mark.parametrize('packages',[COMMON+['hpia'],COMMON+['lenovo_system_update'],[],['hpia'],['lenovo_system_update'],COMMON+['hpia','lenovo_system_update']])
def test_api_keeps_exact_software_selection_in_profile_and_windows_plan(system,packages):
    client,data=system
    image,_,_,deployment=prepare(client,data)
    options=client.get('/api/state',headers=auth()).json()['customization_options']
    assert {'hpia','lenovo_system_update'} <= {p['id'] for p in options['software_packages']}
    profile=client.post('/api/profiles',headers=auth(),json={'name':'Selected software','asset_id':image['id'],'settings':{'software_mode':'winget','winget_packages':packages}})
    assert profile.status_code==201,profile.text
    assert profile.json()['settings']['winget_packages']==packages
    job=client.post('/api/deployments',headers=auth(),json={**deployment,'profile_id':profile.json()['id'],'wizard_enabled':True}).json()
    plan=client.get('/api/agent/'+job['id']+'/plan',headers=auth(job['agent_token'])).json()
    assert plan['settings']['winget_packages']==packages
    selected=client.post('/api/agent/'+job['id']+'/configure',headers=auth(job['agent_token']),json={'profile_id':profile.json()['id'],'hostname':'PC-LAB-01','settings':{**profile.json()['settings'],'winget_packages':packages}})
    assert selected.status_code==200,selected.text
    assert selected.json()['settings']['winget_packages']==packages
    rejected=client.post('/api/profiles',headers=auth(),json={'name':'Unsafe','asset_id':image['id'],'settings':{'winget_packages':['Lenovo.SystemUpdate;cmd.exe']}})
    assert rejected.status_code==422


@pytest.mark.skipif(not PWSH or os.name=='nt',reason='PowerShell and Linux executable fixture required')
@pytest.mark.parametrize('packages',[[],['vlc'],COMMON,COMMON+['hpia'],COMMON+['lenovo_system_update'],COMMON+['hpia','lenovo_system_update']])
@pytest.mark.parametrize('powershell51',[False,True],ids=['modern-json','powershell51-json'])
def test_client_installs_only_checked_packages_with_vendor_manifest_architecture(tmp_path,packages,powershell51):
    shutil.copy(ROOT/'scripts'/'software-sources.json',tmp_path/'software-sources.json')
    exe=tmp_path/'winget.exe'
    exe.write_text('''#!/usr/bin/env python3
import sys,json,pathlib
args=sys.argv[1:]
with open(__file__+'.calls','a') as f:f.write(json.dumps(args)+'\\n')
if args[args.index('--id')+1]=='HP.ImageAssistant':
 p=pathlib.Path(args[args.index('--location')+1])/'HPImageAssistant.exe'
 p.write_bytes(b'Signed HP fixture, never executed')
else:
 names={'VideoLAN.VLC':('VLC media player','VideoLAN','vlc.exe'),'Adobe.Acrobat.Reader.64-bit':('Adobe Acrobat (64-bit)','Adobe','Acrobat.exe'),'Google.Chrome':('Google Chrome','Google LLC','chrome.exe'),'AnyDesk.AnyDesk':('AnyDesk','AnyDesk Software GmbH','AnyDesk.exe'),'Lenovo.SystemUpdate':('Lenovo System Update','Lenovo','tvsu.exe')}
 name,publisher,file=names[args[args.index('--id')+1]]
 folder=pathlib.Path(__file__).parent/name
 folder.mkdir(exist_ok=True)
 (folder/file).write_bytes(b'Installed executable fixture')
 registry=pathlib.Path(__file__+'.registry.json')
 entries=json.loads(registry.read_text()) if registry.exists() else []
 entries.append(dict(DisplayName=name,Publisher=publisher,DisplayVersion='1.2.3',InstallLocation=str(folder),DisplayIcon=str(folder/file)))
 registry.write_text(json.dumps(entries))
''');exe.chmod(0o755)
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
$env:ProgramFiles='PROGRAM'
. 'CLIENT'
. 'FILES'
function Get-AtelierClientWinGet {return 'EXE'}
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=HP Inc.'}}}
function icacls.exe {$global:LASTEXITCODE=0}
function Get-ItemProperty {param($Path);if(Test-Path 'EXE.registry.json'){$records=Get-Content 'EXE.registry.json' -Raw|ConvertFrom-Json;foreach($record in $records){$record}}}
$packages=ConvertFrom-Json 'PACKAGES'
$results=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @($packages) -OnProgress {param($Percent,$Message)})
ConvertTo-Json -InputObject $results -Depth 6|Set-Content 'RESULT' -Encoding UTF8
""".replace('PROGRAM',str(tmp_path/'Program Files')).replace('CLIENT',str(ROOT/'scripts'/'Client-Software.ps1'))
    .replace('FILES',str(ROOT/'scripts'/'Unattend.ps1')).replace('EXE',str(exe)).replace('PACKAGES',json.dumps(packages))
    .replace('DATA',str(tmp_path)).replace('RESULT',str(tmp_path/'result.json')),encoding='utf-8-sig')
    if powershell51:
        wrapper.write_text(r"""# Match Windows PowerShell 5.1's non-enumerated root JSON array.
function ConvertFrom-Json {
 [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)][string]$InputObject)
 process { Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate }
}
"""+wrapper.read_text(encoding='utf-8-sig'),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    result=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))
    assert [r['id'] for r in result]==packages
    names={p['key']:p['name'] for p in json.loads((ROOT/'scripts'/'software-sources.json').read_text())}
    names.update(hpia='HP Image Assistant',lenovo_system_update='Lenovo System Update')
    assert [r['name'] for r in result]==[names[p] for p in packages]
    assert all(r['status']=='completed' for r in result)
    calls=Path(str(exe)+'.calls')
    args=[json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
    expected={'vlc':'VideoLAN.VLC','reader':'Adobe.Acrobat.Reader.64-bit','chrome':'Google.Chrome','anydesk':'AnyDesk.AnyDesk','hpia':'HP.ImageAssistant','lenovo_system_update':'Lenovo.SystemUpdate'}
    assert [a[a.index('--id')+1] for a in args]==[expected[p] for p in packages]
    for a in args:
        assert '--silent' in a and '--disable-interactivity' in a
        if a[a.index('--id')+1]=='Lenovo.SystemUpdate':
            assert a[a.index('--architecture')+1]=='x86' and a[a.index('--scope')+1]=='machine'
