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


@pytest.mark.parametrize('central',[False,True])
def test_local_report_inventory_and_offline_pdf(tmp_path,central):
    data = tmp_path / 'data'; data.mkdir()
    out = tmp_path / 'IQ'; out.mkdir()
    shutil.copy(ROOT/'scripts'/'Reporting.ps1', data/'Reporting.ps1')
    timings=data/'timings';timings.mkdir()
    (timings/'image.json').write_text(json.dumps({'run_id':'d1694e35-1c13-4e09-a8f6-d8b2ce03848d','source':'winpe','stage':'image','status':'completed','started_at':'2026-10-19T09:00:00Z','duration_seconds':125}))
    (data/'result.json').write_text(json.dumps({'status':'completed','applications':[{'name':'VLC','status':'completed','exit_code':0}]}))
    (data/'maintenance.json').write_text(json.dumps({'status':'completed','windows':{'status':'up_to_date','titles':[]},'store':{'status':'requested'}}))
    (out/'Licence-Windows.json').write_text('{"etat":"ACTIVE"}')
    if central:
        (data/'personalization.json').write_text(json.dumps({'settings':{'central_inventory':True}}))
        cache=data/'Inventory';cache.mkdir()
        (cache/'Inventaire-Technique.xml').write_text('before-updates')
        (cache/'Inventaire-Technique.csv').write_text('before-updates')
        (data/'Export-Inventaire.ps1').write_text('''param($OutputDirectory)
Add-Content (Join-Path (Split-Path $OutputDirectory -Parent) 'collections') 'collect'
Set-Content (Join-Path $OutputDirectory 'Inventaire-Technique.xml') 'after-updates'
Set-Content (Join-Path $OutputDirectory 'Inventaire-Technique.csv') 'after-updates'
[pscustomobject]@{SectionsIndisponibles=0}
''',encoding='utf-8-sig')
    wrapper = tmp_path/'run.ps1'
    wrapper.write_text("""
$env:COMPUTERNAME='PC-LAB-01'
function Get-CimInstance { param($ClassName,$OperationTimeoutSec)
    [pscustomobject]@{Manufacturer='HP';Model='EliteBook (test)';TotalPhysicalMemory=16GB;SerialNumber='TEST123456';SMBIOSBIOSVersion='1.2';Caption='Windows 11 Pro';Version='10.0.26200';BuildNumber='26200';OSArchitecture='64 bits';Name='Test CPU';NumberOfCores=4;NumberOfLogicalProcessors=8;Size=512GB;IPEnabled=$true;Description='Ethernet';MACAddress='00:11:22:33:44:55';IPAddress=@('192.168.99.10')}
}
function Get-ItemProperty { param($Path,$Name) [pscustomobject]@{HiberbootEnabled=0;EditionID='Professional'} }
& 'SCRIPT' -DataPath 'DATA' -OutputDirectory 'OUTPUT'
& 'SCRIPT' -DataPath 'DATA' -OutputDirectory 'OUTPUT'
""".replace('SCRIPT',str(ROOT/'scripts'/'New-DeploymentReport.ps1')).replace('DATA',str(data)).replace('OUTPUT',str(out)),encoding='utf-8-sig')
    result = subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode == 0, result.stderr
    report=json.loads((out/'Rapports'/'Rapport-Deploiement.json').read_text(encoding='utf-8-sig'))
    assert report['status']=='completed' and report['inventory']['Numero de serie']=='TEST123456'
    assert any(step['name']=='Duree - Application de Windows' and '125' in step['message'] for step in report['steps'])
    pdf=(out/'Rapports'/'Rapport-Deploiement.pdf').read_bytes()
    assert pdf.startswith(b'%PDF-1.4') and b'TEST123456' in pdf and b'%%EOF' in pdf
    assert b'125 secondes mesurees' in pdf
    start=int(pdf.split(b'startxref\n')[1].splitlines()[0])
    assert pdf[start:].startswith(b'xref\n')

    if central:
        assert (data/'collections').read_text().splitlines()==['collect']
        assert (data/'Inventory'/'Inventaire-Technique.xml').read_text(encoding='utf-8-sig').strip()=='after-updates'
        assert not (out/'Inventaire-Technique.xml').exists()
