"""Execute the shared XML generator and hardware rules; no Windows operations."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
NS = {'u': 'urn:schemas-microsoft-com:unattend'}
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell is required for XML execution tests')


def execute(tmp_path, script):
    wrapper = tmp_path / 'verify.ps1'
    helper = str(ROOT / 'scripts' / 'Unattend.ps1').replace("'", "''")
    wrapper.write_text("$ErrorActionPreference='Stop'\n. '"+helper+"'\n"+script, encoding='utf-8-sig')
    result = subprocess.run([PWSH, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                             '-File', str(wrapper)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    return result.stdout.lstrip('\ufeff').strip()


@pytest.mark.parametrize('owner', ['', 'Equipe & IT <atelier> "Paris"'])
def test_unattend_settings_escaping_and_first_logon_without_credentials(tmp_path, owner):
    plan = {'hostname':'HP-TEST-01', 'locale':'fr-FR', 'settings':{
        'keyboard':'040c:0000040c', 'timezone':'Romance Standard Time', 'user_locale':'fr-CH',
        'registered_owner':owner, 'organization':owner}}
    fixture = tmp_path / 'plan.json'
    fixture.write_text(json.dumps(plan), encoding='utf-8')
    fixture_path = str(fixture).replace("'", "''")
    xml = execute(tmp_path, "$plan=Get-Content -LiteralPath '"+fixture_path+"' -Raw | ConvertFrom-Json\nNew-AtelierUnattend -Plan $plan")
    document = ET.fromstring(xml)
    assert [p.attrib['pass'] for p in document] == ['specialize','oobeSystem']
    assert document.find('.//u:ComputerName', NS).text == 'HP-TEST-01'
    assert document.find('.//u:TimeZone', NS).text == plan['settings']['timezone']
    assert document.find('.//u:InputLocale', NS).text == plan['settings']['keyboard']
    assert document.find('.//u:UILanguage', NS).text == 'fr-FR'
    assert document.find('.//u:UserLocale', NS).text == 'fr-CH'
    registered = document.find('.//u:RegisteredOwner', NS)
    assert (registered.text if registered is not None else '') == owner
    assert 'C:\\ProgramData\\AtelierPXE\\Start-Preparation.ps1' in document.find('.//u:CommandLine', NS).text
    assert '-WindowStyle Hidden' in document.find('.//u:CommandLine', NS).text
    # Interactive OOBE also runs the universal Fast Startup configuration.
    assert 'Prepare-Windows.ps1' in document.find('.//u:RunSynchronousCommand/u:Path', NS).text
    assert document.find('.//u:UserAccounts', NS) is None
    assert document.find('.//u:AutoLogon', NS) is None
    assert 'Password' not in xml and 'Token' not in xml.replace('publicKeyToken', '')


def test_manufacturer_filter_multiple_brands_and_unknown_model(tmp_path):
    output = execute(tmp_path, """
$cases=@(
    (Test-AtelierManufacturer 'hp' 'HP'),
    (Test-AtelierManufacturer 'hp' 'Hewlett-Packard'),
    (Test-AtelierManufacturer 'hp' 'LENOVO'),
    (Test-AtelierManufacturer 'lenovo' 'LENOVO'),
    (Test-AtelierManufacturer 'lenovo' 'HP'),
    (Test-AtelierManufacturer 'all' 'Dell Inc.'),
    (Test-AtelierManufacturer 'hp' 'Dell Inc.')
)
ConvertTo-Json -InputObject $cases -Compress
""")
    assert json.loads(output) == [True,True,False,True,False,True,False]


def test_automatic_windows_builtin_account_and_oobe(tmp_path):
    fixture = tmp_path / 'plan.json'
    fixture.write_text(json.dumps({'hostname':'LE-T15-2378', 'locale':'fr-FR', 'settings':{
        'unattended':True,'keyboard':'040c:0000040c','timezone':'Romance Standard Time','user_locale':'fr-FR'}}))
    xml = execute(tmp_path, "$plan=Get-Content -LiteralPath '"+str(fixture).replace("'","''")+"' -Raw | ConvertFrom-Json\nNew-AtelierUnattend -Plan $plan")
    document=ET.fromstring(xml)
    assert document.find('.//u:AutoLogon/u:Username',NS).text == 'Administrator'
    assert document.find('.//u:AutoLogon/u:Password/u:Value',NS).text is None
    assert document.find('.//u:AdministratorPassword/u:Value',NS).text is None
    assert document.find('.//u:AutoLogon/u:Enabled',NS).text == 'true'
    assert 'Prepare-Windows.ps1' in document.find('.//u:RunSynchronousCommand/u:Path',NS).text
    assert document.find('.//u:HideOnlineAccountScreens',NS).text == 'true'
    assert document.find('.//u:SkipMachineOOBE',NS) is None
    assert document.find('.//u:SkipUserOOBE',NS) is None
    assert 'BypassNRO' not in xml
