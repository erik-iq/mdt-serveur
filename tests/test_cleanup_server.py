"""Exercise the actual deletion plan in an isolated tree, including protected paths."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell required')


@pytest.mark.parametrize('whatif', [False, True])
def test_cleanup_preserves_active_unknown_recent_backups_and_links(tmp_path, whatif):
    install=tmp_path/'console';install.mkdir()
    data=tmp_path/'data';data.mkdir()
    (install/'data-runtime.json').write_text(json.dumps({'data_dir':str(data)}))
    staging=tmp_path/'staging';staging.mkdir()
    backup=tmp_path/'backups';backup.mkdir()
    old=[]
    for i in range(5):
        folder=staging/('Atelier-3-'+f'{i:032x}')
        project=folder/('mdt-serveur-'+'a'*40)/'scripts'
        project.mkdir(parents=True)
        (project/'Update-Console.ps1').write_text('# Project marker')
        old.append(folder)
    active=old[1]
    link=old[2]/'external'
    link.symlink_to(data, target_is_directory=True)
    unknown=staging/'Atelier-3-unrelated';unknown.mkdir()
    no_marker=staging/('Maj-Atelier2-'+'f'*32);no_marker.mkdir()
    backups=[]
    for i in range(5):
        folder=backup/('atelier3-'+f'{i:032x}');folder.mkdir()
        (folder/'console').mkdir()
        (folder/'console'/'data-runtime.json').write_text('{}')
        (folder/'deployment.sqlite3').write_bytes(b'fixture')
        os.utime(folder,(10000+i,10000+i));backups.append(folder)
    script=tmp_path/'run.ps1'
    args={'SCRIPT':str(ROOT/'scripts'/'Clear-AtelierObsolete.ps1'), 'INSTALL':str(install), 'STAGING':str(staging), 'BACKUP':str(backup), 'ACTIVE':str(active)}
    body="& 'SCRIPT' -InstallPath 'INSTALL' -SearchRoots @('STAGING') -BackupDirectory 'BACKUP' -ProtectedPaths @('ACTIVE') -MinimumAgeHours 0 -Confirm:$false"
    for key,value in args.items():body=body.replace(key,value.replace("'","''"))
    script.write_text(body+(' -WhatIf' if whatif else ''),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    assert active.exists() and old[2].exists() and data.exists() and install.exists()
    assert unknown.exists() and no_marker.exists()
    if whatif:
        assert all(x.exists() for x in old+backups)
        assert not (data/'cleanup').exists()
    else:
        assert not old[0].exists() and not old[3].exists() and not old[4].exists()
        assert not backups[0].exists() and not backups[1].exists()
        assert all(x.exists() for x in backups[2:])
        log=json.loads(next((data/'cleanup').glob('*.json')).read_text(encoding='utf-8-sig'))
        assert len(log)==5


@pytest.mark.parametrize('case',['retired','failed_extraction','unknown','edited_script','locked','linked','protected','whatif','old_build'])
def test_retired_hp_winpe_cache_and_original_helper_only(tmp_path,case):
    import hashlib
    install=tmp_path/'console';scripts=install/'scripts';scripts.mkdir(parents=True)
    data=tmp_path/'data';data.mkdir()
    root=tmp_path/'Atelier';root.mkdir()
    (install/'data-runtime.json').write_text(json.dumps({'data_dir':str(data)}))
    fixture=b'# retired published HP extraction fixture\n'
    (scripts/'WinPE-HPDrivers.ps1').write_bytes(fixture+(b'# local change\n' if case=='edited_script' else b''))
    (scripts/'WinPE-IntelDrivers.ps1').write_text('# current Intel helper')
    (scripts/'Build-WinPE.ps1').write_text(". 'WinPE-HPDrivers.ps1'" if case=='old_build' else ". 'WinPE-IntelDrivers.ps1'")
    retired=root/'Drivers/WinPE-Official/HP-sp173204';retired.mkdir(parents=True)
    if case=='failed_extraction':
        (retired/'extraction-result.json').write_text('{"softpaq":"sp173204","exit_code":1168}')
        (retired/'sp173204.exe').write_text('old extraction fixture')
    else:
        (retired/'manifest.json').write_text(json.dumps({'softpaq':'other' if case=='unknown' else 'sp173204','source':'https://ftp.ext.hp.com/pub/softpaq/sp173001-173500/sp173204.exe'}))
    if case=='linked':(retired/'external').symlink_to(data,target_is_directory=True)
    for relative in ('Drivers/WinPE-Official/Intel-I219-31.2.2','HP-Repository','Inventaires'):
        folder=root/relative;folder.mkdir(parents=True)
        (folder/'keep.txt').write_text('current data')
    # Replace a production allowlisted hash only inside this fixture copy.
    helper=(ROOT/'scripts/Clear-AtelierObsolete.ps1').read_text().replace('#requires -RunAsAdministrator\n','')
    helper=helper.replace('e580877959aea2535f524189e5300ce2bdf85a7737632462a5c646defe535e4f',hashlib.sha256(fixture).hexdigest())
    (scripts/'cleanup.ps1').write_text(helper)
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
$held=$null
if ('CASE' -eq 'locked') { $held=[IO.File]::Open('RETIRED/build.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
try {
 & 'INSTALL/scripts/cleanup.ps1' -InstallPath 'INSTALL' -SearchRoots @('ROOT') -BackupDirectory 'WORK/no-backups' -ProtectedPaths @($(if('CASE' -eq 'protected'){'RETIRED'})) -MinimumAgeHours 0 -Confirm:$false -WhatIf:('CASE' -eq 'whatif')
} finally { if ($held) { $held.Dispose() } }
'''.replace('CASE',case).replace('WORK',str(tmp_path)).replace('INSTALL',str(install)).replace('ROOT',str(root)).replace('RETIRED',str(retired)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=25)
    assert run.returncode==0,run.stdout+run.stderr
    assert retired.exists()==(case in {'unknown','locked','linked','protected','whatif','old_build'})
    assert (scripts/'WinPE-HPDrivers.ps1').exists()==(case in {'edited_script','whatif','old_build'})
    for relative in ('Drivers/WinPE-Official/Intel-I219-31.2.2','HP-Repository','Inventaires'):
        assert (root/relative/'keep.txt').read_text()=='current data'
    if case=='whatif':assert not (data/'cleanup').exists() and not (retired/'build.lock').exists()
