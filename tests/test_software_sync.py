import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

from test_api import auth, prepare, register, system

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


def test_update_software_preserves_bundle_reference_and_blocks_live_jobs(system):
    client,data=system
    _,_,_,deployment=prepare(client,data)
    old=register(client,data,'old.exe','application')
    new=register(client,data,'new.exe','application')
    body={'name':'VLC','version':'1','asset_id':old['id'],'arguments':'/S'}
    app=client.post('/api/applications',headers=auth(),json=body).json()
    bundle=client.post('/api/bundles',headers=auth(),json={'name':'Standard','application_ids':[app['id']]}).json()
    replacement={**body,'version':'2','asset_id':new['id']}
    route='/api/applications/'+app['id']
    assert client.put(route,json=replacement).status_code==401
    job=client.post('/api/deployments',headers=auth(),json=deployment).json()
    assert client.put(route,headers=auth(),json=replacement).status_code==409
    assert client.get('/api/state',headers=auth()).json()['applications'][0]['asset_id']==old['id']
    client.post('/api/deployments/'+job['id']+'/cancel',headers=auth())
    updated=client.put(route,headers=auth(),json=replacement)
    assert updated.status_code==200 and updated.json()['id']==app['id']
    state=client.get('/api/state',headers=auth()).json()
    assert state['bundles'][0]['application_ids']==bundle['application_ids']
    assert next(a for a in state['applications'] if a['id']==app['id'])['asset_id']==new['id']
    # The old immutable installer is preserved for audit and rollback.
    assert (data/'artifacts'/'old.exe').exists()


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
@pytest.mark.parametrize('case',['valid','wrong_hash','wrong_publisher','wrong_host','ambiguous'])
def test_winget_export_validation_rejects_untrusted_or_ambiguous_download(tmp_path,case):
    import hashlib
    binary=b'fixture-installer-not-executed'
    (tmp_path/'package.exe').write_bytes(binary)
    sha=hashlib.sha256(binary).hexdigest() if case!='wrong_hash' else '0'*64
    url='https://download.videolan.org/vlc/test.exe' if case!='wrong_host' else 'https://untrusted.invalid/test.exe'
    manifest=f'PackageIdentifier: VideoLAN.VLC\nPackageVersion: "3.0.99"\nInstallers:\n- Architecture: x64\n  InstallerSha256: {sha}\n  InstallerUrl: {url}\n'
    if case=='ambiguous':manifest+='  InstallerSha256: '+sha+'\n'
    (tmp_path/'package.yaml').write_text(manifest)
    wrapper=tmp_path/'run.ps1'
    publisher='CN=VideoLAN, O=VideoLAN, C=FR' if case!='wrong_publisher' else 'CN=Someone else'
    wrapper.write_text("""
$ErrorActionPreference='Stop'
. 'HELPER'
function Get-AuthenticodeSignature { param($LiteralPath);[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='PUBLISHER'}} }
$source=Get-Content 'SOURCES' -Raw | ConvertFrom-Json | Where-Object { $_.key -eq 'vlc' }
try { $result=Get-AtelierDownloadedInstaller 'DATA' $source;@{status='accepted';version=$result.version} | ConvertTo-Json -Compress }
catch { @{status='rejected'} | ConvertTo-Json -Compress }
""".replace('HELPER',str(ROOT/'scripts'/'Software-Sync.ps1')).replace('PUBLISHER',publisher).replace('SOURCES',str(ROOT/'scripts'/'software-sources.json')).replace('DATA',str(tmp_path)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=20)
    assert run.returncode==0,run.stderr
    result=json.loads(run.stdout)
    assert result['status']==('accepted' if case=='valid' else 'rejected')
    if case=='valid':assert result['version']=='3.0.99'


@pytest.mark.skipif(not PWSH or os.name=='nt',reason='Linux executable shim for WinGet')
def test_sync_download_publish_then_unchanged_run_keeps_application_id(tmp_path):
    import hashlib
    data=tmp_path/'data';data.mkdir();(data/'artifacts').mkdir()
    (data/'artifacts'/'old-vlc.exe').write_bytes(b'previous version')
    install=tmp_path/'installed';install.mkdir()
    (install/'data-runtime.json').write_text(json.dumps({'data_dir':str(data),'base_url':'https://console.invalid','internal_mode':True}))
    state={'applications':[{'id':'stable-app','name':'VLC','version':'old','asset_id':'old-asset','install_mode':'install','manufacturer':'all','arguments':'/S'}],
           'assets':[],'bundles':[{'application_ids':['stable-app']}],'profiles':[],'deployments':[]}
    statefile=tmp_path/'state.json';statefile.write_text(json.dumps(state))
    executable=tmp_path/'winget.exe'
    executable.write_text('''#!/usr/bin/env python3
import sys, pathlib, hashlib
folder=pathlib.Path(sys.argv[sys.argv.index('--download-directory')+1])
assert sys.argv[1]=='download' and '--ignore-security-hash' not in sys.argv
payload=b'new signed installer fixture'
(folder/'VLC.exe').write_bytes(payload)
(folder/'VLC.yaml').write_text('PackageIdentifier: VideoLAN.VLC\\nPackageVersion: 3.0.99\\nInstallers:\\n- Architecture: x64\\n  InstallerUrl: https://download.videolan.org/vlc/test.exe\\n  InstallerSha256: '+hashlib.sha256(payload).hexdigest()+'\\n')
''');executable.chmod(0o755)
    wrapper=tmp_path/'run-sync.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
function Get-AuthenticodeSignature { param($LiteralPath);[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=VideoLAN, O=VideoLAN, C=FR'}} }
function Invoke-RestMethod {
    param($Uri,$Method,$Headers,$TimeoutSec,$ContentType,$Body)
    $state=Get-Content 'STATE' -Raw | ConvertFrom-Json
    if ($Method -eq 'GET') { return $state }
    $bodyObject=[Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
    if ($Uri.EndsWith('/assets')) {
        $asset=[pscustomobject]@{id='new-asset';filename=$bodyObject.filename}
        $state.assets=@($asset);$result=$asset
    } elseif ($Method -eq 'PUT' -and $Uri.EndsWith('/applications/stable-app')) {
        Add-Content 'LOG' 'PUT'
        $bodyObject | Add-Member NoteProperty id 'stable-app'
        $state.applications=@($bodyObject);$result=$bodyObject
    } else { throw ('Unexpected API mutation : '+$Uri) }
    $state | ConvertTo-Json -Depth 8 | Set-Content 'STATE'
    return $result
}
& 'SCRIPT' -InstallPath 'INSTALL' -Packages vlc
& 'SCRIPT' -InstallPath 'INSTALL' -Packages vlc
'''.replace('STATE',str(statefile)).replace('LOG',str(tmp_path/'mutations')).replace('SCRIPT',str(ROOT/'scripts'/'Sync-Applications.ps1')).replace('INSTALL',str(install)),encoding='utf-8-sig')
    env={**os.environ,'PATH':str(tmp_path)+os.pathsep+os.environ['PATH']}
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30,env=env)
    assert run.returncode==0,run.stderr
    assert (tmp_path/'mutations').read_text().splitlines()==['PUT']
    result=json.loads((data/'software-sync'/'last-sync.json').read_text(encoding='utf-8-sig'))
    assert result['applications'][0]['status']=='unchanged'
    assert result['applications'][0]['application_id']=='stable-app'
    assert (data/'artifacts'/'old-vlc.exe').read_bytes()==b'previous version'
