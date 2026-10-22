"""Exercise the new Windows helpers with isolated exécutable and API fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def ps(path):
    return str(path).replace("'","''")


@pytest.mark.skipif(os.name=='nt',reason='Linux executable fixture')
def test_silent_client_install_failure_isolated_and_completed_packages_are_not_reinstalled(tmp_path):
    shutil.copy(ROOT/'scripts'/'software-sources.json',tmp_path/'software-sources.json')
    executable=tmp_path/'winget.exe'
    executable.write_text('''#!/usr/bin/env python3
import sys,pathlib,json
args=sys.argv[1:]
assert args[0]=='install' and '--silent' in args and '--disable-interactivity' in args
assert args[args.index('--scope')+1]=='machine'
key=args[args.index('--id')+1]
with open(__file__+'.calls','a') as handle: handle.write(key+'\\n')
print('Fixture '+key)
if key=='VideoLAN.VLC':(pathlib.Path(__file__).parent/'vlc.exe').write_bytes(b'Installed VLC fixture')
sys.exit(12 if key=='Google.Chrome' else 0)
''');executable.chmod(0o755)
    wrapper=tmp_path/'client.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
. 'HELPER'
. 'FILES'
function Get-AtelierClientWinGet { return 'EXE' }
function Get-ItemProperty {param($Path)
 if(Test-Path 'DATA/vlc.exe'){[pscustomobject]@{DisplayName='VLC media player';Publisher='VideoLAN';DisplayVersion='3.0';InstallLocation='DATA';DisplayIcon='DATA/vlc.exe'}}
}
$first=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @('vlc','chrome') -OnProgress {param($Percent,$Message)})
$second=@(Install-AtelierClientSoftware -DataPath 'DATA' -Packages @('vlc','chrome') -OnProgress {param($Percent,$Message)})
@{first=$first;second=$second}|ConvertTo-Json -Depth 6|Set-Content 'RESULT'
""".replace('HELPER',ps(ROOT/'scripts'/'Client-Software.ps1')).replace('FILES',ps(ROOT/'scripts'/'Unattend.ps1')).replace('EXE',ps(executable)).replace('DATA',ps(tmp_path)).replace('RESULT',ps(tmp_path/'results.json')),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    result=json.loads((tmp_path/'results.json').read_text(encoding='utf-8-sig'))
    assert [x['status'] for x in result['first']]==['completed','failed']
    assert [x['status'] for x in result['second']]==['completed','failed']
    assert (tmp_path/'winget.exe.calls').read_text().splitlines()==['VideoLAN.VLC','Google.Chrome','Google.Chrome']
    assert 'Fixture Google.Chrome' in (tmp_path/'software-logs'/'chrome.log').read_text(encoding='utf-8-sig')


def test_inventory_transfer_sends_each_file_once_and_retries_only_changed_file(tmp_path):
    cache=tmp_path/'Inventory';cache.mkdir()
    (cache/'Inventaire-Technique.xml').write_text('<InventaireOrdinateur ordinateur="PC-TEST"/>')
    (cache/'Inventaire-Technique.csv').write_text('Ordinateur;Catégorie;Propriété;Valeur\nPC-TEST;CPU;Nom;Test\n')
    (tmp_path/'reporting.json').write_text(json.dumps({'server_url':'https://atelier.test','id':'job','token':'private-report-token'}))
    wrapper=tmp_path/'transfer.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
. 'SCRIPT'
function Invoke-RestMethod {param($Uri,$Method,$Headers,$ContentType,$InFile,$TimeoutSec)
    if($Headers.Authorization -ne 'Bearer private-report-token'){throw 'Missing scoped token'}
    if(-not(Test-Path $InFile)){throw 'File missing'}
    Add-Content 'LOG' $Uri
    return @{accepted=$true}
}
if(-not(Send-AtelierInventory 'DATA' 'CACHE')){throw 'First upload failed'}
if(-not(Send-AtelierInventory 'DATA' 'CACHE')){throw 'Idempotent upload failed'}
Add-Content 'CSV' 'PC-TEST;RAM;Taille;16'
if(-not(Send-AtelierInventory 'DATA' 'CACHE')){throw 'Changed upload failed'}
""".replace('SCRIPT',ps(ROOT/'scripts'/'Inventory-Transfer.ps1')).replace('LOG',ps(tmp_path/'uploads')).replace('DATA',ps(tmp_path)).replace('CACHE',ps(cache)).replace('CSV',ps(cache/'Inventaire-Technique.csv')),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=20)
    assert run.returncode==0,run.stderr
    assert [line.rsplit('/',1)[-1] for line in (tmp_path/'uploads').read_text().splitlines()]==['xml','csv','csv']


@pytest.mark.parametrize('old_name',['WinPE-Atelier2-old','WinPE-Reprise-old','WinPE-v1'])
@pytest.mark.parametrize('keep_registered',[True,False])
@pytest.mark.parametrize('root_alias',[True,False])
def test_cleanup_removes_only_old_atelier_images_after_replacement_is_present(tmp_path,old_name,keep_registered,root_alias):
    keep=tmp_path/'WinPE-Atelier3-new';keep.mkdir()
    (keep/'atelier-winpe.json').write_text('{"release":"ATELIER-4"}')
    (keep/'media'/'sources').mkdir(parents=True);(keep/'media'/'sources'/'boot.wim').write_bytes(b'new')
    old=tmp_path/old_name;(old/'media'/'sources').mkdir(parents=True);(old/'media'/'sources'/'boot.wim').write_bytes(b'old')
    unrelated=tmp_path/'MDT-WinPE';unrelated.mkdir()
    mdt=tmp_path/'WinPE-MDT';(mdt/'media'/'sources').mkdir(parents=True);(mdt/'media'/'sources'/'boot.wim').write_bytes(b'mdt')
    search_root=tmp_path
    if root_alias:
        search_root=tmp_path/'alias'
        search_root.symlink_to(tmp_path,target_is_directory=True)
    wrapper=tmp_path/'cleanup.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
function Import-Module {param($Name)}
function Get-WdsBootImage {
 if(REGISTERED){[pscustomobject]@{ImageName='Atelier PXE - ATELIER-4 - new';Architecture='x64';FileName='new.wim'}}
 [pscustomobject]@{ImageName='Atelier PXE - ATELIER-2 - old';Architecture='x64';FileName='old.wim'}
 [pscustomobject]@{ImageName='MDT Production';Architecture='x64';FileName='mdt.wim'}
 [pscustomobject]@{ImageName='Atelier MDT Production';Architecture='x64';FileName='litetouch.wim'}
}
function Get-WindowsImage {param([switch]$Mounted)}
function wdsutil.exe {Add-Content 'LOG' ($args -join '|');$global:LASTEXITCODE=0}
& 'SCRIPT' -KeepImageName 'Atelier PXE - ATELIER-4 - new' -KeepOutputPath 'KEEP' -SearchRoots @('ROOT') -Confirm:$false
""".replace('REGISTERED','$true' if keep_registered else '$false').replace('LOG',ps(tmp_path/'removed')).replace('SCRIPT',ps(ROOT/'scripts'/'Remove-OldAtelierWinPE.ps1')).replace('KEEP',ps(keep)).replace('ROOT',ps(search_root)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=20)
    if not keep_registered:
        assert run.returncode!=0
        assert old.exists() and keep.exists() and not (tmp_path/'removed').exists()
        return
    assert run.returncode==0,run.stderr
    assert old.exists()==root_alias and keep.exists() and unrelated.exists() and mdt.exists()
    log=(tmp_path/'removed').read_text()
    assert '/Image:Atelier PXE - ATELIER-2 - old' in log and 'MDT Production' not in log and '/Filename:new.wim' not in log


@pytest.mark.skipif(os.name=='nt',reason='Linux Python executable fixture')
@pytest.mark.parametrize('active',[False,True])
def test_activation_disables_legacy_worker_or_leaves_configuration_unchanged_when_busy(tmp_path,active):
    import sqlite3
    import sys
    install=tmp_path/'console';(install/'scripts').mkdir(parents=True);(install/'.venv'/'Scripts').mkdir(parents=True)
    os.symlink(sys.executable,install/'.venv'/'Scripts'/'python.exe')
    data=tmp_path/'data';data.mkdir();(data/'internal-share.json').write_text('{}')
    config={'data_dir':str(data),'base_url':'https://atelier.test','port':12345,'internal_mode':True}
    (install/'data-runtime.json').write_text(json.dumps(config))
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute('CREATE TABLE software_jobs(status TEXT)')
        if active:con.execute("INSERT INTO software_jobs VALUES ('running')")
    scriptdir=tmp_path/'source';scriptdir.mkdir()
    for name in ['Enable-Atelier3.ps1','Console-Installation.ps1','Unattend.ps1']:
        shutil.copy(ROOT/'scripts'/name,scriptdir/name)
    wrapper=tmp_path/'activation.ps1'
    wrapper.write_text("""$ErrorActionPreference='Stop'
function Stop-ScheduledTask {param($TaskName);Add-Content 'LOG' ('stop '+$TaskName)}
function Start-ScheduledTask {param($TaskName);Add-Content 'LOG' ('start '+$TaskName)}
function Disable-ScheduledTask {param($TaskName);Add-Content 'LOG' ('disable '+$TaskName)}
function Get-ScheduledTask {param($TaskName,$ErrorAction);[pscustomobject]@{State='Ready'}}
function Invoke-RestMethod {param($Uri,$TimeoutSec);@{auto_enroll=$true;client_software=$true}}
& 'SCRIPT' -InstallPath 'INSTALL'
""".replace('LOG',ps(tmp_path/'actions')).replace('SCRIPT',ps(scriptdir/'Enable-Atelier3.ps1')).replace('INSTALL',ps(install)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=20)
    result=json.loads((install/'data-runtime.json').read_text(encoding='utf-8-sig'))
    actions=(tmp_path/'actions').read_text()
    if active:
        assert run.returncode!=0 and result==config
        assert 'start AtelierPXE-Console' in actions and 'disable AtelierPXE-SoftwareSync' not in actions
    else:
        assert run.returncode==0,run.stderr
        assert result['auto_enroll'] and result['client_software']
        assert 'disable AtelierPXE-SoftwareSync' in actions
