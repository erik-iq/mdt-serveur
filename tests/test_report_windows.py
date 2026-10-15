"""Create real PDF bytes with simulated CIM; no Windows installation required."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell required')


def test_local_report_inventory_and_offline_pdf(tmp_path):
    data = tmp_path / 'data'; data.mkdir()
    out = tmp_path / 'IQ'; out.mkdir()
    shutil.copy(ROOT/'scripts'/'Reporting.ps1', data/'Reporting.ps1')
    (data/'result.json').write_text(json.dumps({'status':'completed','applications':[{'name':'VLC','status':'completed','exit_code':0}]}))
    (data/'maintenance.json').write_text(json.dumps({'status':'completed','windows':{'status':'up_to_date','titles':[]},'store':{'status':'requested'}}))
    (out/'Licence-Windows.json').write_text('{"etat":"ACTIVE"}')
    wrapper = tmp_path/'run.ps1'
    wrapper.write_text("""
$env:COMPUTERNAME='PC-LAB-01'
function Get-CimInstance { param($ClassName,$OperationTimeoutSec)
    [pscustomobject]@{Manufacturer='HP';Model='EliteBook (test)';TotalPhysicalMemory=16GB;SerialNumber='TEST123456';SMBIOSBIOSVersion='1.2';Caption='Windows 11 Pro';Version='10.0.26200';BuildNumber='26200';OSArchitecture='64 bits';Name='Test CPU';NumberOfCores=4;NumberOfLogicalProcessors=8;Size=512GB;IPEnabled=$true;Description='Ethernet';MACAddress='00:11:22:33:44:55';IPAddress=@('192.168.99.10')}
}
function Get-ItemProperty { param($Path,$Name) [pscustomobject]@{HiberbootEnabled=0;EditionID='Professional'} }
& 'SCRIPT' -DataPath 'DATA' -OutputDirectory 'OUTPUT'
""".replace('SCRIPT',str(ROOT/'scripts'/'New-DeploymentReport.ps1')).replace('DATA',str(data)).replace('OUTPUT',str(out)),encoding='utf-8-sig')
    result = subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode == 0, result.stderr
    report=json.loads((out/'Rapport-Deploiement.json').read_text(encoding='utf-8-sig'))
    assert report['status']=='completed' and report['inventory']['Numero de serie']=='TEST123456'
    pdf=(out/'Rapport-Deploiement.pdf').read_bytes()
    assert pdf.startswith(b'%PDF-1.4') and b'TEST123456' in pdf and b'%%EOF' in pdf
    start=int(pdf.split(b'startxref\n')[1].splitlines()[0])
    assert pdf[start:].startswith(b'xref\n')
