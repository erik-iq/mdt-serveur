import csv
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def test_xml_csv_hardware_arrays_missing_sections_and_no_secrets(tmp_path):
    wrapper=tmp_path/'inventory.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
$env:COMPUTERNAME='PC-INVENTAIRE'
function Get-CimInstance {
    param($ClassName,$Namespace,$Filter,$OperationTimeoutSec,$ErrorAction)
    if ($ClassName -eq 'Win32_Product') { throw 'Must never trigger MSI repair' }
    if ($ClassName -eq 'Win32_PhysicalMemory') { throw 'Provider unavailable' }
    if ($ClassName -eq 'SoftwareLicensingProduct') { return [pscustomobject]@{Name='Windows(R) Pro';LicenseStatus=1;ProductKeyChannel='OEM:DM';LicenseIsAddon=$false;OA3xOriginalProductKey='SECRET-LICENSE';PartialProductKey='SECRET-PARTIAL'} }
    if ($ClassName -eq 'SoftwareLicensingService') { return [pscustomobject]@{Version='1';OA3xOriginalProductKey='SECRET-OEM'} }
    [pscustomobject]@{Name='Écran & SSD <test>';SerialNumber='TEST-123';MemorySize=16GB;IPAddress=@('192.168.99.10','fe80::123');FirmwareText='a'+[char]0+'b';Formula='=@SUM(1)'}
}
function Get-PhysicalDisk { param($ErrorAction);[pscustomobject]@{FriendlyName='SSD';MediaType='SSD';Size=512GB;SerialNumber='SSD123';HealthStatus='Healthy'} }
function Get-StorageReliabilityCounter { param([Parameter(ValueFromPipeline)]$Disk,$ErrorAction);process { [pscustomobject]@{Temperature=35;PowerOnHours=1234;Wear=2;ReadErrorsUncorrected=0} } }
function Get-Volume { param($ErrorAction);[pscustomobject]@{DriveLetter='C';Size=500GB;SizeRemaining=400GB;FileSystemType='NTFS'} }
function Get-Tpm { param($ErrorAction);[pscustomobject]@{TpmPresent=$true;TpmReady=$true;OwnerAuth='SECRET-TPM'} }
function Confirm-SecureBootUEFI { param($ErrorAction);$true }
function Get-BitLockerVolume { param($ErrorAction);[pscustomobject]@{MountPoint='C:';ProtectionStatus='On';KeyProtector='SECRET-BITLOCKER'} }
function Get-ItemProperty {
    param($Path,$ErrorAction)
    [pscustomobject]@{EditionID='Professional';CurrentBuild='26200';DigitalProductId='SECRET-REGISTRY';DisplayName='Test application';DisplayVersion='1.2';Publisher='Test publisher';UninstallString='SECRET-COMMAND';HiberbootEnabled=0}
}
function Get-TimeZone { param($ErrorAction);[pscustomobject]@{Id='UTC';BaseUtcOffset=[timespan]::Zero} }
function Get-NetRoute { param($ErrorAction);[pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop='192.168.99.1'} }
function Get-AppxPackage { param([switch]$AllUsers,$ErrorAction);[pscustomobject]@{Name='Test.StoreApp';Version='1.2';Architecture='X64'} }
& 'SCRIPT' -OutputDirectory 'DATA' | Out-Null
# A second run safely replaces the previous exports.
& 'SCRIPT' -OutputDirectory 'DATA' | Out-Null
'''.replace('SCRIPT',str(ROOT/'scripts'/'Export-Inventaire.ps1')).replace('DATA',str(tmp_path)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr
    xml=(tmp_path/'Inventaire-Technique.xml').read_text(encoding='utf-8-sig')
    document=ET.fromstring(xml)
    assert document.attrib['ordinateur']=='PC-INVENTAIRE'
    sections={s.attrib['nom']:s.attrib for s in document.findall('./Collecte/Section')}
    assert sections['BarrettesRAM']['etat']=='indisponible'
    assert sections['DisquesPhysiques_SSD_HDD']['etat']=='ok'
    assert 'SECRET-' not in xml
    assert (tmp_path/'Inventaire-Technique.csv').read_bytes().startswith(b'\xef\xbb\xbf')
    rows=list(csv.DictReader((tmp_path/'Inventaire-Technique.csv').open(encoding='utf-8-sig',newline=''),delimiter=';'))
    assert any(r['Categorie']=='LicencesWindows' and r['Propriete']=='ProductKeyChannel' and r['Valeur']=='OEM:DM' for r in rows)
    assert any(r['Propriete']=='IPAddress[1]' and r['Valeur']=='fe80::123' for r in rows)
    assert any(r['Valeur']=="'=@SUM(1)" for r in rows)
    assert 'SECRET-' not in (tmp_path/'Inventaire-Technique.csv').read_text()
    assert any(p.text=='=@SUM(1)' for p in document.findall('./Proprietes/Propriete'))
    assert any(p.text=='\u00c9cran & SSD <test>' for p in document.findall('./Proprietes/Propriete'))
    assert not list(tmp_path.glob('*.tmp'))
