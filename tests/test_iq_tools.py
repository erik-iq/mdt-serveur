"""Create IQ_ tools with simulated Windows licensing/battery APIs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize(('battery','license_status'),[(False,1),(True,0),(True,5)])
def test_iq_reports_wallpaper_and_launchers(tmp_path,battery,license_status):
    data=tmp_path/'payload'
    data.mkdir()
    (data/'Resources').mkdir()
    image=b'\x89PNG\r\n\x1a\nIQ test image'
    (data/'Resources'/'Fond-Atelier.png').write_bytes(image)
    (data/'personalization.json').write_text(json.dumps({'wallpaper':{'filename':'Fond-Atelier.png','sha256':hashlib.sha256(image).hexdigest()}}))
    for name in ['Test-Batterie.ps1','Verifier-Licence.ps1','Test-Materiel.ps1','Tests-Materiel.html','Verifier-Garantie.ps1','Export-Inventaire.ps1','Theme.ps1','theme.json','brand-logo.png']:
        shutil.copy(ROOT/'scripts'/name,data/name)
    output=tmp_path/'IQ tools'
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
function icacls.exe { $global:LASTEXITCODE=0 }
function Get-CimInstance {
    param($ClassName,$Filter)
    if ($ClassName -eq 'Win32_Battery') { if (HAS_BATTERY) { [pscustomobject]@{Name='Test battery'} }; return }
    if ($Filter -notmatch '55c92734-d682-4d71-983e-d6ec3f16059f') { throw 'Windows licensing scope missing' }
    [pscustomobject]@{Name='Windows(R), Professional edition';LicenseStatus=LICENSE_STATUS;LicenseIsAddon=$false;GracePeriodRemaining=0}
}
function powercfg.exe {
    $path=$args[[Array]::IndexOf($args,'/output')+1]
    [IO.File]::WriteAllText($path,'<html>Simulated battery report</html>')
    $global:LASTEXITCODE=0
}
& 'PREPARE' -DataPath 'DATA' -OutputDirectory 'OUTPUT'
# Parse and execute only the generated command with a fake Start-Process.
function Start-Process { param($FilePath,$Verb,$ArgumentList); $script:launcherArguments=$ArgumentList }
$line=(Get-Content 'OUTPUT/Diagnostics/Test-Batterie.cmd')[1]
$command=$line.Substring($line.IndexOf('-Command "')+10).TrimEnd('"')
$command=$command.Replace('%~dp0',('OUTPUT/Diagnostics'+[IO.Path]::DirectorySeparatorChar))
& ([scriptblock]::Create($command))
$expected='-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path 'OUTPUT/Diagnostics' 'Test-Batterie.ps1')+'"'
if ($script:launcherArguments -ne $expected) { throw ('Incorrect launcher: '+$script:launcherArguments) }
'''.replace('HAS_BATTERY','$true' if battery else '$false').replace('LICENSE_STATUS',str(license_status))
      .replace('PREPARE',str(ROOT/'scripts'/'Prepare-IQTools.ps1').replace("'","''"))
      .replace('DATA',str(data).replace("'","''")).replace('OUTPUT',str(output).replace("'","''")),encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    assert set(p.name for p in output.iterdir())=={'Lisez-moi.txt','Diagnostics','Licence','Rapports','Inventaire','Garantie','Personnalisation'}
    assert (output/'Personnalisation'/'Fond-Atelier.png').read_bytes()==image
    assert (output/'Diagnostics'/'Rapport-batterie.html').exists()==battery
    assert (output/'Diagnostics'/'Batterie-absente.txt').exists()==(not battery)
    report=json.loads((output/'Licence'/'Licence-Windows.json').read_text(encoding='utf-8-sig'))
    assert report['etat']==('ACTIVE' if license_status==1 else 'NON ACTIVE')
    assert all(r['status']=='completed' for r in json.loads((output/'Diagnostics'/'Diagnostics.json').read_text(encoding='utf-8-sig')))
