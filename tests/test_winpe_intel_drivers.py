"""Exercise official boot driver caching and DISM orchestration with vendor calls mocked."""
import hashlib
import zipfile
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


def execute(tmp_path,source,powershell=PWSH):
    script=tmp_path/'run.ps1'
    script.write_text(source.replace('PROJECT',str(ROOT).replace("'","''"))
                      .replace('WORK',str(tmp_path).replace("'","''")),encoding='utf-8-sig')
    run=subprocess.run([powershell,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=45)
    assert run.returncode==0,run.stdout+run.stderr
    return json.loads(run.stdout.splitlines()[-1])


HASH='2cbff42aa02519e49f02d8e95a6572c44310e97fe67c42e299f2aba6ea9344f5'
INF=r'''[Version]
Signature="$Windows NT$"
Class=Net
DriverVer=04/19/2026,12.19.2.65
CatalogFile=e1d.cat
[Manufacturer]
%Intel%=Intel,NTamd64.10.0...17763
[Intel.NTamd64.10.0...17763]
%LM%=Install,PCI\VEN_8086&DEV_15D7
%V%=Install,PCI\VEN_8086&DEV_15D8
'''


def archive_fixture(tmp_path,case):
    files={'PRO1000/Winx64/NDIS68/e1d.inf':INF,
           'PRO1000/Winx64/NDIS68/e1d.cat':'fixture catalog',
           'PRO1000/Winx64/NDIS68/e1d.sys':'fixture binary'}
    # NetAdapterCx, other NICs and a future-only I219 must never be substituted.
    for folder,name,content in [('NDIS85','e1d.inf',INF.replace('17763','30000')),
                                ('NetAdapterCx','e1dn.inf',INF.replace('12.19.2.65','99.0.0.0')),
                                ('OtherNIC','e2f.inf',INF.replace('12.19.2.65','99.0.0.0'))]:
        files.update({f'{folder}/{name}':content,f'{folder}/e1d.cat':'cat',f'{folder}/e1d.sys':'sys'})
    if case=='newer_compatible':
        files.update({'Newer/e1d68x64.inf':INF.replace('12.19.2.65','12.20.0.1'),
                      'Newer/e1d.cat':'catalog','Newer/e1d68x64.sys':'driver'})
    if case=='too_new':files['PRO1000/Winx64/NDIS68/e1d.inf']=INF.replace('17763','30000')
    if case=='x86':files['PRO1000/Winx64/NDIS68/e1d.inf']=INF.replace('NTamd64','NTx86')
    if case=='missing_cat':del files['PRO1000/Winx64/NDIS68/e1d.cat']
    if case=='missing_sys':del files['PRO1000/Winx64/NDIS68/e1d.sys']
    if case=='missing_id':files['PRO1000/Winx64/NDIS68/e1d.inf']=INF.replace('DEV_15D8','DEV_0000')
    if case=='specific_section':
        files['PRO1000/Winx64/NDIS68/e1d.inf']=INF.replace('=Intel,NTamd64.10.0...17763','=Intel,NTamd64.10.0...17763,NTamd64.10.0...26100')+'[Intel.NTamd64.10.0...26100]\n%Other%=Install,PCI\\VEN_8086&DEV_0000\n'
    if case=='traversal':files['../outside.txt']='must not escape'
    if case=='duplicate':files['PRO1000/Winx64/NDIS68/E1D.INF']='must not overwrite'
    if case=='absolute':files['/outside.txt']='must not escape'
    if case=='reserved':files['PRO1000/NUL.txt']='must not create device'
    archive=tmp_path/'fixture.zip'
    with zipfile.ZipFile(archive,'w') as z:
        for name,body in files.items():z.writestr(name,body)
        if case=='symlink':
            entry=zipfile.ZipInfo('link');entry.create_system=3;entry.external_attr=0o120777 << 16
            z.writestr(entry,'../outside')
    helper=(ROOT/'scripts/WinPE-IntelDrivers.ps1').read_text().replace(HASH,hashlib.sha256(archive.read_bytes()).hexdigest())
    (tmp_path/'helper.ps1').write_text(helper)


@pytest.mark.parametrize('case',['cache','modified','missing','invalid_cached_archive','newer_compatible','bad_hash','download_failure','locked',
    'too_new','x86','missing_cat','missing_sys','missing_id','specific_section','traversal','duplicate','absolute','reserved','symlink'])
def test_real_zip_cache_and_compatible_single_inf_selection(tmp_path,case):
    archive_fixture(tmp_path,case)
    result=execute(tmp_path,r'''
$ErrorActionPreference='Stop'
. 'WORK/helper.ps1'
$script:downloads=0
function Invoke-WebRequest {
 param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec)
 if ($Uri -cne 'https://downloadmirror.intel.com/923981/Wired_driver_31.2.2_x64.zip') { throw 'Unexpected source' }
 $script:downloads++
 Copy-Item 'WORK/fixture.zip' $OutFile
 if ('CASE' -eq 'bad_hash') { Add-Content $OutFile 'corruption' }
 if ('CASE' -eq 'download_failure') { throw 'Download interrupted' }
}
$failed=$false;$message='';$held=$null;$selected=@();$version=''
$cache='WORK/cache with spaces/Intel-I219-31.2.2'
if ('CASE' -eq 'locked') {
 New-Item -ItemType Directory -Path $cache -Force | Out-Null
 $held=[IO.File]::Open((Join-Path $cache 'build.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
try {
 $first=Get-AtelierIntelI219Driver -CacheRoot 'WORK/cache with spaces' -WinPEVersion '10.0.26100.1'
 $second=Get-AtelierIntelI219Driver -CacheRoot 'WORK/cache with spaces' -WinPEVersion '10.0.26100.1'
 if ('CASE' -in @('modified','missing')) {
  $file=Join-Path $cache 'drivers/PRO1000/Winx64/NDIS68/e1d.sys'
  if ('CASE' -eq 'modified') { Set-Content $file 'tampered' } else { Remove-Item $file }
  $second=Get-AtelierIntelI219Driver -CacheRoot 'WORK/cache with spaces' -WinPEVersion '10.0.26100.1'
  if ((Get-Content $file -Raw).Trim() -ne 'fixture binary') { throw 'Cache not repaired' }
 }
 if ('CASE' -eq 'invalid_cached_archive') {
  Set-Content (Join-Path $cache 'Wired_driver_31.2.2_x64.zip') 'invalid cached archive'
  $second=Get-AtelierIntelI219Driver -CacheRoot 'WORK/cache with spaces' -WinPEVersion '10.0.26100.1'
 }
 $selected=@($second.network_infs);$version=$second.version
} catch { $failed=$true;$message=$_.Exception.Message }
finally { if ($held) { $held.Dispose() } }
@{failed=$failed;message=$message;downloads=$script:downloads;selected=$selected;version=$version;manifest=(Test-Path (Join-Path $cache 'manifest.json'));partial=(Test-Path (Join-Path $cache 'Wired_driver_31.2.2_x64.zip.partial'));staging=@(Get-ChildItem $cache -Directory -Filter 'extract-*').Count} | ConvertTo-Json -Depth 4 -Compress
'''.replace('CASE',case))
    success=case in {'cache','modified','missing','invalid_cached_archive','newer_compatible'}
    assert result['failed'] != success,result
    assert result['downloads']==(0 if case=='locked' else 2 if case=='invalid_cached_archive' else 1)
    assert result['manifest']==success
    assert not result['partial'] and not result['staging']
    if success:
        assert len(result['selected'])==1
        assert result['selected'][0].endswith('Newer/e1d68x64.inf' if case=='newer_compatible' else 'PRO1000/Winx64/NDIS68/e1d.inf')
        assert result['version']==('12.20.0.1' if case=='newer_compatible' else '12.19.2.65')
    else:assert not result['selected']
    assert not (tmp_path/'cache with spaces/Intel-I219-31.2.2/outside.txt').exists()


@pytest.mark.parametrize('case',['success','prepare_failure','driver_failure','missing_store'])
def test_real_build_adds_network_infs_and_preserves_old_image_on_failure(tmp_path,case):
    source=tmp_path/'source';shutil.copytree(ROOT/'scripts',source)
    build=source/'Build-WinPE.ps1'
    # Only remove the Windows administrator requirement for this simulated ADK.
    build.write_text(build.read_text().replace('#requires -RunAsAdministrator\n',''))
    helper="""
function Get-AtelierIntelI219Driver {
 param($CacheRoot,$WinPEVersion)
 if ('CASE' -eq 'prepare_failure') { throw 'HP pack unavailable' }
 return [pscustomobject]@{network_infs=@('WORK/e1d.inf');family='fixture'}
}
""".replace('CASE',case).replace('WORK',str(tmp_path))
    (tmp_path/'e1d.inf').write_text('[Version]\nClass=Net')
    (source/'WinPE-IntelDrivers.ps1').write_text(helper)
    adk=tmp_path/'adk'/'Windows Kits'/'10'/'Assessment and Deployment Kit'
    (adk/'Deployment Tools').mkdir(parents=True)
    (adk/'Deployment Tools'/'DandISetEnv.bat').touch()
    (adk/'Windows Preinstallation Environment'/'amd64'/'WinPE_OCs').mkdir(parents=True)
    (adk/'Windows Preinstallation Environment'/'copype.cmd').touch()
    (tmp_path/'old-boot.wim').write_text('Existing working image')
    result=execute(tmp_path,r'''
$ErrorActionPreference='Stop'
${env:ProgramFiles(x86)}='WORK/adk';$env:SystemRoot='WORK'
$global:atelierDriverTestAdded=New-Object 'Collections.Generic.List[string]'
$global:atelierDriverTestCopied=$false;$global:atelierDriverTestSaved=$false;$global:atelierDriverTestDiscarded=$false;$global:atelierDriverTestImported=$false
function Start-Process {
 param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$Wait,[switch]$PassThru)
 if ($FilePath -like '*cmd.exe') {
  $global:atelierDriverTestCopied=$true
  New-Item -ItemType Directory -Path 'WORK/output/mount/Windows/System32','WORK/output/media/sources' -Force | Out-Null
  Set-Content 'WORK/output/media/sources/boot.wim' 'New image fixture'
 }
 return [pscustomobject]@{ExitCode=0}
}
function Get-WindowsImage { [CmdletBinding()]param($ImagePath,$Index) return [pscustomobject]@{Version='10.0.26100.1'} }
function Mount-WindowsImage {param($ImagePath,$Index,$Path)}
function Add-WindowsPackage {param($Path,$PackagePath)}
function Add-WindowsDriver {
 [CmdletBinding()]param($Path,$Driver,[switch]$Recurse,[switch]$ForceUnsigned)
 if ($ForceUnsigned -or $Recurse) { throw 'Official network INFs must be individually validated by DISM' }
 if ('CASE' -eq 'driver_failure') { throw 'DISM rejected driver' }
 $global:atelierDriverTestAdded.Add($Driver)
 $store=Join-Path $Path 'Windows/System32/DriverStore/FileRepository/e1d.inf_amd64_0123456789abcdef'
 New-Item -ItemType Directory -Path $store -Force | Out-Null
 if ('CASE' -ne 'missing_store') { Copy-Item $Driver (Join-Path $store 'e1d.inf') }
 Set-Content (Join-Path $store 'inbox-kept.inf') 'ADK inbox fixture'

}
function Dismount-WindowsImage {param($Path,[switch]$Save,[switch]$Discard) $global:atelierDriverTestSaved=[bool]$Save;$global:atelierDriverTestDiscarded=[bool]$Discard}
function Import-Module {param($Name)}
function Import-WdsBootImage {param($Path,$NewImageName) $global:atelierDriverTestImported=$true}
$failed=$false
try { & 'WORK/source/Build-WinPE.ps1' -ServerUrl 'https://192.168.99.250' -OutputPath 'WORK/output' -DriverCacheRoot 'WORK/cache' -ImportIntoWds }
catch { $failed=$true;$message=$_.Exception.Message }
@{failed=$failed;message=$message;copied=$global:atelierDriverTestCopied;added=@($global:atelierDriverTestAdded.ToArray());saved=$global:atelierDriverTestSaved;discarded=$global:atelierDriverTestDiscarded;imported=$global:atelierDriverTestImported;marker=(Test-Path 'WORK/output/atelier-winpe.json');old=(Get-Content 'WORK/old-boot.wim' -Raw).Trim()} | ConvertTo-Json -Compress
'''.replace('CASE',case))
    assert result['old']=='Existing working image'
    assert result['failed']==(case!='success'),result.get('message')
    assert result['copied']==(case!='prepare_failure')
    assert result['added']==([str(tmp_path/'e1d.inf')] if case in {'success','missing_store'} else [])
    assert result['saved']==result['marker']==result['imported']==(case=='success')
    assert result['discarded']==(case in {'driver_failure','missing_store'})


    if case=='success':
        cfg=json.loads((tmp_path/'output/mount/Atelier/config.json').read_text(encoding='utf-8-sig'))
        assert cfg['i219_recovery']['inf'].endswith('e1d.inf')
        assert cfg['i219_recovery']['sha256']==hashlib.sha256((tmp_path/'e1d.inf').read_bytes()).hexdigest()
        assert (tmp_path/'output/mount/Windows/System32/DriverStore/FileRepository/e1d.inf_amd64_0123456789abcdef/inbox-kept.inf').exists()
