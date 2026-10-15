"""Use actual WIM metadata indices rather than assuming Home is always index 1."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def test_sync_only_adds_present_compatible_editions_with_real_index(tmp_path):
    state={'assets':[{'id':'wim-id','kind':'windows','filename':'multi.wim'}],
           'profiles':[{'asset_id':'wim-id','image_index':6,'locale':'fr-FR','windows_version':'11','settings':{'theme':'dark'}}]}
    (tmp_path/'state.json').write_text(json.dumps(state))
    (tmp_path/'data-runtime.json').write_text(json.dumps({'data_dir':str(tmp_path),'internal_mode':True,'base_url':'https://example.invalid'}))
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
function Invoke-RestMethod {
    param($Uri,$Headers,$Method,$ContentType,$Body)
    if ($Uri.EndsWith('/api/state')) { return Get-Content 'DATA/state.json' -Raw | ConvertFrom-Json }
    [Text.Encoding]::UTF8.GetString($Body) | Set-Content 'DATA/created.json'
}
function Get-WindowsImage {
    param($ImagePath,$Index)
    if (-not $Index) { @(2,6,8,10) | ForEach-Object { [pscustomobject]@{ImageIndex=$_} };return }
    $edition=switch ($Index) { 2 {'Core'};6 {'Professional'};8 {'Enterprise'};10 {'CoreSingleLanguage'} }
    [pscustomobject]@{ImageIndex=$Index;EditionId=$edition;Languages=@($(if($Index -eq 10){'en-US'}else{'fr-FR'}))}
}
& 'SCRIPT' -InstallPath 'DATA'
'''.replace('DATA',str(tmp_path)).replace('SCRIPT',str(ROOT/'scripts'/'Sync-WindowsEditions.ps1')),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=20)
    assert result.returncode==0,result.stderr
    created=json.loads((tmp_path/'created.json').read_text(encoding='utf-8-sig'))
    assert created['edition']=='Famille' and created['image_index']==2
    assert created['settings']['theme']=='dark'
