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
