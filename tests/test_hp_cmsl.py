"""Run the real CMSL orchestration and ZIP writer with isolated HP API fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid
import zipfile

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['success','bad_signature','empty_recommendations'])
def test_unrecognized_os_uses_exact_recommended_packages_without_faking_version_or_running_installer(tmp_path,case):
    identifier=str(uuid.uuid4())
    script=r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
$script:downloads=0
# Enforce real adapted properties, as Windows PowerShell 5.1's measurement
# requires, rather than PowerShell 7's dictionary-key convenience.
function Measure-Object {
 [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject,[string]$Property,[switch]$Sum)
 begin{$items=New-Object 'Collections.Generic.List[object]'}
 process{
  if(-not $InputObject.PSObject.Properties[$Property]){throw 'A real measured property is required in Windows PowerShell 5.1'}
  $items.Add($InputObject)
 }
 end{$items | Microsoft.PowerShell.Utility\Measure-Object -Property $Property -Sum:$Sum}
}
function Add-HPRepositoryFilter {param([ValidateSet('24H2','25H2')][string]$OsVer);throw 'An unsupported OS must never use a substitute filter'}
function Get-AtelierHpCmslCommand {param($Name);if($Name -eq 'Add-HPRepositoryFilter'){return Get-Command Add-HPRepositoryFilter};return $Name}
function Get-HPSoftpaq {
 param($Number,$SaveAs,[switch]$Quiet,$Overwrite)
 if($Number -notin @('12345','23456') -or $Overwrite -ne 'skip'){throw 'Unexpected acquisition request'}
 $script:downloads++;Set-Content -LiteralPath $SaveAs 'Fixture - never executed'
}
function Get-HPSoftpaqMetadataFile {param($Number,$SaveAs,[switch]$Quiet,$Overwrite);if(-not(Test-Path -LiteralPath $SaveAs)){Set-Content -LiteralPath $SaveAs 'Fixture CVA'}}
function Get-AuthenticodeSignature {
 param($LiteralPath)
 return [pscustomobject]@{Status=$(if('CASE' -eq 'bad_signature'){'NotSigned'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=HP Inc.'}}
}
$job=[pscustomobject]@{id='ID';platform='83B2';os='win11';os_version='26H2';required_softpaqs=$(if('CASE' -eq 'empty_recommendations'){@()}else{@('SP12345','SP23456')})}
$failed=$false;$message=''
try {
 $one=Sync-AtelierHpRepository -DataRoot 'DATA' -Job $job
 $job.id=[guid]::NewGuid().ToString()
 $two=Sync-AtelierHpRepository -DataRoot 'DATA' -Job $job
} catch {$failed=$true;$message=$_.Exception.Message}
@{failed=$failed;message=$message;downloads=$script:downloads} | ConvertTo-Json -Compress
'''.replace('LIBRARY',str(ROOT/'scripts'/'HP-Repository.ps1')).replace('CASE',case).replace('ID',identifier).replace('DATA',str(tmp_path))
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=35)
    assert run.returncode==0,run.stderr
    result=json.loads(run.stdout.splitlines()[-1])
    assert result['failed']==(case!='success'),result
    path=tmp_path/'hp-repository'/'snapshots'/(identifier+'.zip')
    if case=='success':
        assert result['downloads']==2
        with zipfile.ZipFile(path) as archive:
            assert set(archive.namelist())=={'.repository/cache/atelier-softpaq-cache.json','sp12345.exe','sp12345.cva','sp23456.exe','sp23456.cva'}
            marker=json.loads(archive.read('.repository/cache/atelier-softpaq-cache.json').decode('utf-8-sig'))
            assert marker['os_version']=='26H2' and marker['mode']=='packages_only'
    else:
        assert not path.exists()


@pytest.mark.parametrize('case',['success','sync_failure','bad_signature','missing_reference','unowned_work','unsafe_link','low_disk'])
def test_cmsl_snapshots_preserve_old_versions_and_never_execute_packages(tmp_path,case):
    first=str(uuid.uuid4());second=str(uuid.uuid4())
    work=tmp_path/'hp-repository'/'work'/'8AB8'/'win11-25H2'
    if case=='unowned_work':work.mkdir(parents=True);(work/'keep.txt').write_text('Unrelated file')
    if case=='unsafe_link':
        outside=tmp_path/'outside';outside.mkdir()
        (tmp_path/'hp-repository').mkdir();(tmp_path/'hp-repository'/'linked').symlink_to(outside,target_is_directory=True)
    script=r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
$script:pass=0
function Get-AtelierHpCmslCommand {param($Name);return $Name}
if('CASE' -eq 'low_disk'){function Get-AtelierHpFreeSpace {return 1GB}}
function Initialize-HPRepository {New-Item -ItemType Directory -Path '.repository/cache/offline' -Force|Out-Null;Set-Content '.repository/config.json' '{"smtp_password":"private-module-configuration"}'}
function Set-HPRepositoryConfiguration {param($Setting,$CacheValue);if($Setting -ne 'OfflineCacheMode' -or $CacheValue -ne 'Enable'){throw 'Offline cache not enabled'}}
function Add-HPRepositoryFilter {param($Platform,$Os,$OsVer,$Category);if($Platform -ne '8AB8' -or $Os -ne 'win11' -or $OsVer -ne '25H2' -or 'Bios' -notin $Category -or 'Firmware' -notin $Category){throw 'Wrong CMSL filter'}}
function Invoke-HPRepositorySync {
 param([switch]$Quiet)
 $script:pass++
 if($script:pass -eq 2 -and -not (Test-Path 'sp12345.exe')){throw 'Previously downloaded package lost before synchronization'}
 Set-Content '.repository/cache/offline/platformList.cab' 'HP reference fixture'
 if('CASE' -ne 'missing_reference'){Set-Content '.repository/cache/8AB8_64_11.0.25h2.cab' 'HP platform reference fixture'}
 if($script:pass -eq 1){Set-Content 'sp12345.exe' 'Signed fixture - never executed';Set-Content 'sp12345.cva' 'Metadata fixture'}
 else{Set-Content 'sp23456.exe' 'New signed fixture - never executed';Set-Content 'sp23456.cva' 'New metadata'}
 if('CASE' -eq 'sync_failure' -and $script:pass -eq 2){throw 'HP network failure'}
}
function Invoke-HPRepositoryCleanup {if($script:pass -eq 2){Remove-Item 'sp12345.exe','sp12345.cva'}}
function Get-AuthenticodeSignature {
 param($LiteralPath)
 $publisher=if('CASE' -eq 'bad_signature' -and $LiteralPath -match 'sp23456'){ 'CN=Other publisher' }else{'CN=HP Inc.'}
 [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject=$publisher}}
}
$job=[pscustomobject]@{id='FIRST';platform='8AB8';os='win11';os_version='25H2'}
try {
 $one=Sync-AtelierHpRepository -DataRoot 'DATA' -Job $job
 $job.id='SECOND'
 $two=Sync-AtelierHpRepository -DataRoot 'DATA' -Job $job
 @{status='success';first=$one;second=$two}|ConvertTo-Json -Depth 5|Set-Content 'DATA/out.json'
} catch {@{status='failed';message=$_.Exception.Message}|ConvertTo-Json|Set-Content 'DATA/out.json'}
'''.replace('LIBRARY',str(ROOT/'scripts'/'HP-Repository.ps1')).replace('CASE',case).replace('FIRST',first).replace('SECOND',second).replace('DATA',str(tmp_path))
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    outcome=json.loads((tmp_path/'out.json').read_text(encoding='utf-8-sig'))
    archive=tmp_path/'hp-repository'/'snapshots'/(first+'.zip')
    if case in {'unowned_work','unsafe_link','missing_reference','low_disk'}:
        assert outcome['status']=='failed' and not archive.exists(),outcome
        if case=='unowned_work':assert (work/'keep.txt').read_text()=='Unrelated file'
    else:
        assert archive.exists(),outcome
        with zipfile.ZipFile(archive) as z:
            assert 'sp12345.exe' in z.namelist() and '.repository/cache/offline/platformList.cab' in z.namelist()
            assert '.repository/config.json' not in z.namelist()
        next_archive=archive.with_name(second+'.zip')
        if case=='success':
            assert outcome['status']=='success',outcome
            with zipfile.ZipFile(next_archive) as z:assert 'sp23456.exe' in z.namelist() and 'sp12345.exe' not in z.namelist()
        else:
            assert outcome['status']=='failed' and not next_archive.exists(),outcome
            if case=='bad_signature':assert not (work/'sp23456.exe').exists()


@pytest.mark.parametrize('case',['current','legacy','wrong_module'])
def test_cmsl_command_resolution_supports_official_and_legacy_names_only(tmp_path,case):
    script=r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
function Get-Command {
 param($Name)
 if('CASE' -eq 'legacy' -and $Name -eq 'Invoke-HPRepositorySync'){return $null}
 [pscustomobject]@{Name=$Name;ModuleName=$(if('CASE' -eq 'wrong_module'){'UnrelatedModule'}else{'HP.Repo'})}
}
try {$command=Get-AtelierHpCmslCommand 'Invoke-HPRepositorySync';@{status='ok';name=$command.Name}|ConvertTo-Json}
catch {@{status='failed'}|ConvertTo-Json}
'''.replace('LIBRARY',str(ROOT/'scripts'/'HP-Repository.ps1')).replace('CASE',case)
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    outcome=json.loads(result.stdout)
    assert outcome['status']==('failed' if case=='wrong_module' else 'ok')
    if case!='wrong_module':assert outcome['name']==('Invoke-RepositorySync' if case=='legacy' else 'Invoke-HPRepositorySync')
