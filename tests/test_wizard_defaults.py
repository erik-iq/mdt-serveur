import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest
from fastapi.testclient import TestClient
from app.main import create_app

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


def test_internal_defaults_choose_registered_atelier_wallpaper_and_swiss_formats(tmp_path):
    with TestClient(create_app(tmp_path,'test-only-admin-token-long-enough','https://atelier.test',internal_mode=True)) as client:
        (tmp_path/'artifacts'/'win.wim').write_bytes(b'MSWIM\0\0\0fixture')
        image=client.post('/api/assets',json={'filename':'win.wim','kind':'windows'}).json()
        profile=client.post('/api/profiles',json={'name':'Windows Pro \u00e9quipe','asset_id':image['id'],'settings':{'user_locale':'fr-FR','registered_owner':'old','organization':'old'}}).json()
        png=tmp_path/'artifacts'/'Fond Atelier.png';png.write_bytes(b'\x89PNG\r\n\x1a\nfixture')
        wallpaper=client.post('/api/assets',json={'filename':png.name,'kind':'wallpaper'})
        assert wallpaper.status_code==201,wallpaper.text
        current=client.get('/api/state').json()['profiles'][0]
        assert current['settings']['user_locale']=='fr-CH'
        assert current['settings']['registered_owner']==current['settings']['organization']==''
        assert current['settings']['wallpaper_asset_id']==wallpaper.json()['id']
        assert current['name']=='Windows Pro \u00e9quipe'


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
@pytest.mark.parametrize(('serial','suffix'), [('5CD123AB78','2378'),('AB000012','0012'),('none',None),('AB12',None)])
def test_wizard_prefills_only_four_digits(tmp_path,serial,suffix):
    script=tmp_path/'test.ps1'
    script.write_text(". '"+str(ROOT/'scripts'/'Naming.ps1')+"'\ntry { @{suffix=(Get-AtelierSerialSuffix '"+serial+"')} | ConvertTo-Json -Compress } catch { @{suffix=$null} | ConvertTo-Json -Compress }")
    result=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    assert json.loads(result.stdout)['suffix']==suffix


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
def test_duration_stopwatch_survives_retries_without_duplicate_sends(tmp_path):
    (tmp_path/'reporting.json').write_text(json.dumps({'server_url':'https://atelier.test','id':'job','token':'private-fixture-token'}))
    script=tmp_path/'test.ps1'
    script.write_text("""$ErrorActionPreference='Stop'
. 'LIBRARY'
function Invoke-RestMethod {param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 if($Headers.Authorization -ne 'Bearer private-fixture-token'){throw 'Wrong reporting scope'}
 Add-Content 'CALLS' ([Text.Encoding]::UTF8.GetString($Body))
}
$id=Start-AtelierTiming 'DATA' 'software'
Start-Sleep -Milliseconds 30
Stop-AtelierTiming 'DATA' $id
Stop-AtelierTiming 'DATA' $id 'failed'
Sync-AtelierTimings 'DATA'
Sync-AtelierTimings 'DATA'
""".replace('LIBRARY',str(ROOT/'scripts'/'Timings.ps1')).replace('CALLS',str(tmp_path/'calls')).replace('DATA',str(tmp_path)),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    calls=(tmp_path/'calls').read_text(encoding='utf-8-sig').splitlines()
    assert len(calls)==1
    row=json.loads(calls[0])['measurements'][0]
    assert row['stage']=='software' and row['status']=='completed' and .02<=row['duration_seconds']<5
