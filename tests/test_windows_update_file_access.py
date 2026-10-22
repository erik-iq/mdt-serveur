"""Accès partagés et écritures atomiques résistantes aux verrous Windows temporaires."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell requis')


@pytest.mark.parametrize('code',[32,33,5])
def test_atomic_writer_retries_only_native_sharing_failures(tmp_path,code):
    # Substituer uniquement la frontière native Replace pour reproduire le code Windows sous Linux.
    source=(ROOT/'scripts/Unattend.ps1').read_text('utf-8-sig')
    source=source.replace('[IO.File]::Replace($temporary,$target,$backup)','Invoke-FixtureReplace $temporary $target $backup')
    (tmp_path/'Unattend.ps1').write_text(source,encoding='utf-8-sig')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
. 'DATA/Unattend.ps1'
$global:replaceCalls=0
function Invoke-FixtureReplace {
 param($Source,$Target,$Backup)
 $global:replaceCalls++
 if($global:replaceCalls -eq 1){throw [IO.IOException]::new('Native fixture',(-2147024896 + CODE))}
 [IO.File]::Replace($Source,$Target,$Backup)
}
$path='DATA/state.json'
[IO.File]::WriteAllText($path,'{"message":"avant"}')
$errorText=''
try {Write-AtelierVerifiedUtf8File -Path $path -Content '{"message":"après"}' -NoBackup|Out-Null}
catch {$errorText=$_.Exception.Message}
@{calls=$global:replaceCalls;error=$errorText;content=(Read-AtelierSharedUtf8File $path);temporary=@(Get-ChildItem 'DATA' -Filter '.atelier-*.tmp').Count}|ConvertTo-Json -Compress
'''.replace('DATA',str(tmp_path)).replace('CODE',str(code)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=15)
    assert run.returncode==0,run.stderr
    value=json.loads(run.stdout)
    assert value['temporary']==0
    assert value['calls']==(1 if code==5 else 2)
    assert json.loads(value['content'])['message']==('avant' if code==5 else 'après')
    assert bool(value['error'])==(code==5)


def test_shared_reader_allows_native_atomic_replacement_and_rejects_invalid_utf8(tmp_path):
    shutil.copy(ROOT/'scripts/Unattend.ps1',tmp_path)
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
. 'DATA/Unattend.ps1'
$path='DATA/state.json'
Write-AtelierVerifiedUtf8File -Path $path -Content '{"message":"prêt"}' -NoBackup|Out-Null
$share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
$held=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
try {
 Write-AtelierVerifiedUtf8File -Path $path -Content '{"message":"terminé"}' -NoBackup|Out-Null
 $read=Read-AtelierSharedUtf8File -Path $path
}finally{$held.Dispose()}
[IO.File]::WriteAllBytes($path,[byte[]]@(0xC3,0x28))
$rejected=$false
try {Read-AtelierSharedUtf8File -Path $path|Out-Null}catch{$rejected=$true}
@{content=$read;rejected=$rejected}|ConvertTo-Json -Compress
'''.replace('DATA',str(tmp_path)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=15)
    assert run.returncode==0,run.stderr
    value=json.loads(run.stdout)
    assert json.loads(value['content'])['message']=='terminé'
    assert value['rejected']
    module=(ROOT/'scripts/WindowsUpdate-First.ps1').read_text('utf-8-sig')
    assert 'Get-Content $path -Encoding UTF8 -Raw' not in module
