"""Exécute the WinPE identity helpers without touching disks or real hardware."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['serial','wrong_serial','empty_macs','generic_bios','generic_all','wmi_failure','dotnet_fallback','legacy','legacy_mismatch'])
def test_serial_controls_target_before_disk_operations_without_requiring_a_mac(tmp_path,case):
    script=r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
function Get-CimInstance {
 [CmdletBinding()]param($ClassName,$OperationTimeoutSec)
 if($ClassName -eq 'Win32_BIOS') {
  if('CASE' -eq 'wmi_failure'){throw 'BIOS WMI fixture unavailable'}
  return [pscustomobject]@{SerialNumber=$(if('CASE' -in @('generic_bios','generic_all')){'To Be Filled By O.E.M.'}else{' hp-sn1234 '})}
 }
 if($ClassName -eq 'Win32_ComputerSystemProduct'){return [pscustomobject]@{IdentifyingNumber=$(if('CASE' -eq 'generic_all'){'00000000'}else{'HP-SN1234'})}}
 if('CASE' -in @('empty_macs','dotnet_fallback')){return}
 if($ClassName -eq 'Win32_NetworkAdapter'){return [pscustomobject]@{MACAddress='00:11:22:33:44:55'}}
 if($ClassName -eq 'Win32_NetworkAdapterConfiguration'){return [pscustomobject]@{MACAddress='00-11-22-33-44-55';IPAddress=@('169.254.1.1')}}
}
function Get-AtelierNetworkInterfaces {
 if('CASE' -ne 'dotnet_fallback'){return}
 $nic=[pscustomobject]@{NetworkInterfaceType=[Net.NetworkInformation.NetworkInterfaceType]::Ethernet}
 $nic|Add-Member ScriptMethod GetPhysicalAddress {return [Net.NetworkInformation.PhysicalAddress]::Parse('001122334466')}
 $nic|Add-Member ScriptMethod GetIPProperties {return [pscustomobject]@{UnicastAddresses=@([pscustomobject]@{Address=[Net.IPAddress]::Parse('192.168.99.15')})}}
 return $nic
}
$serial=Get-AtelierHardwareSerial
$network=Get-AtelierWinPENetwork
$plan=[pscustomobject]@{serial_number=$(if('CASE' -like 'legacy*'){''}elseif('CASE' -eq 'wrong_serial'){'HP-OTHER1234'}else{'HP-SN1234'});mac=$(if('CASE' -eq 'legacy'){'00:11:22:33:44:55'}else{'00:11:22:33:44:99'})}
try { Assert-AtelierMachineIdentity $plan;$allowed=$true;$message='' }catch{$allowed=$false;$message=$_.Exception.Message}
@{serial=$serial;network=$network;allowed=$allowed;message=$message;generic=@('Unknown','Not Available','00000000','FFFF','Default string','System Serial Number','TO BE FILLED BY O.E.M.'|ForEach-Object{ConvertTo-AtelierSerialNumber $_})}|ConvertTo-Json -Depth 6
'''.replace('LIBRARY',str(ROOT/'scripts'/'WinPE-Session.ps1').replace("'","''")).replace('CASE',case)
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=35)
    assert run.returncode==0,run.stderr
    result=json.loads(run.stdout)
    assert result['allowed']==(case not in {'wrong_serial','generic_all','legacy_mismatch'}),result
    assert result['serial']==('' if case=='generic_all' else 'HP-SN1234')
    assert not any(result['generic'])
    if case=='empty_macs':assert result['network']['macs']==[] and result['allowed']
    if case=='dotnet_fallback':
        assert result['network']['macs']==['00:11:22:33:44:66']
        assert result['network']['ipv4']==['192.168.99.15']
    if not result['allowed']:assert 'Aucun disque effacé' in result['message']
