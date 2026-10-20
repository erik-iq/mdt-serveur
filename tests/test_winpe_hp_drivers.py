"""Exercise official boot driver caching and DISM orchestration with vendor calls mocked."""
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


@pytest.mark.parametrize('case',['cache','modified','missing','bad_signature','wrong_publisher',
                                 'download_failure','extract_failure','empty_pack','timeout','locked','missing_code','start_failure'])
def test_cache_reuse_repair_and_failure_before_driver_injection(tmp_path,case):
    result=execute(tmp_path,r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/WinPE-HPDrivers.ps1'
$script:downloads=0;$script:extractions=0;$script:killed=0;$script:disposed=0
function Invoke-WebRequest {
 param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec)
 $script:downloads++
 if ($Uri -cne 'https://ftp.ext.hp.com/pub/softpaq/sp173001-173500/sp173204.exe') { throw 'Unexpected source' }
 Set-Content $OutFile 'HP signed fixture, never executed'
 if ('CASE' -eq 'download_failure') { throw 'Interrupted download' }
}
function Get-AuthenticodeSignature {
 [CmdletBinding()]param($LiteralPath)
 [pscustomobject]@{Status=$(if ('CASE' -eq 'bad_signature'){'NotTrusted'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject=$(if ('CASE' -eq 'wrong_publisher'){'CN=Other Publisher, O=Other'}else{'CN=HP Inc., O=HP Inc., C=US'})}}
}
function New-AtelierWinPEExtractionProcess {
 param($Package,$Destination)
 $script:extractions++
 $folder=$Destination
 if ('CASE' -ne 'empty_pack') {
  New-Item -ItemType Directory -Path (Join-Path $folder 'network') | Out-Null
  Set-Content (Join-Path $folder 'network/ethernet.inf') "[Version]`nClass=Net`nCatalogFile=ethernet.cat"
  Set-Content (Join-Path $folder 'network/ethernet.sys') 'driver fixture'
  Set-Content (Join-Path $folder 'network/ethernet.cat') 'catalog fixture'
  Set-Content (Join-Path $folder 'storage.inf') "[Version]`nClass=SCSIAdapter"
  Set-Content (Join-Path $folder 'wifi.inf') "[Version]`nClass=Net`n[Wireless.Ndi]`n*IfType=71"
 }
 $process=[pscustomobject]@{ExitCode=$(if ('CASE' -eq 'extract_failure'){7}elseif ('CASE' -eq 'missing_code'){$null}else{0})}
 $process | Add-Member ScriptMethod Start {return ('CASE' -ne 'start_failure')}
 $process | Add-Member ScriptMethod WaitForExit {param($Timeout) if ($Timeout -notin @(600000,5000)){throw 'Missing extraction timeout'};return ('CASE' -ne 'timeout')}
 $process | Add-Member ScriptMethod Kill {$script:killed++}
 $process | Add-Member ScriptMethod Dispose {$script:disposed++}
 return $process
}
$failed=$false;$message='';$held=$null;$selected=@()
$cache='WORK/cache with spaces/HP-sp173204'
if ('CASE' -eq 'locked') {
 New-Item -ItemType Directory -Path $cache -Force | Out-Null
 $held=[IO.File]::Open((Join-Path $cache 'build.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
try {
 $first=Get-AtelierWinPEHpDrivers -CacheRoot 'WORK/cache with spaces'
 $second=Get-AtelierWinPEHpDrivers -CacheRoot 'WORK/cache with spaces'
 $selected=@($second.network_infs | ForEach-Object {[IO.Path]::GetFileName($_)})
 if ('CASE' -in @('modified','missing')) {
  $file=Join-Path $second.path 'network/ethernet.sys'
  if ('CASE' -eq 'modified') { Set-Content $file 'tampered' } else { Remove-Item $file }
  $third=Get-AtelierWinPEHpDrivers -CacheRoot 'WORK/cache with spaces'
  if ((Get-Content (Join-Path $third.path 'network/ethernet.sys') -Raw).Trim() -ne 'driver fixture') { throw 'Cache not restored' }
 }
} catch { $failed=$true;$message=$_.Exception.Message }
finally { if ($held) { $held.Dispose() } }
@{failed=$failed;message=$message;downloads=$script:downloads;extractions=$script:extractions;killed=$script:killed;disposed=$script:disposed;selected=$selected;manifest=(Test-Path (Join-Path $cache 'manifest.json'));partial=(Test-Path (Join-Path $cache 'sp173204.partial.exe'));staging=@(Get-ChildItem $cache -Directory -Filter 'extract-*').Count} | ConvertTo-Json -Compress
'''.replace('CASE',case))
    success=case in {'cache','modified','missing'}
    assert result['failed'] != success,result
    assert result['downloads']==(0 if case=='locked' else 1)
    assert result['extractions']==(2 if case in {'modified','missing'} else
                                   1 if case in {'cache','extract_failure','empty_pack','timeout','missing_code','start_failure'} else 0)
    assert result['disposed']==result['extractions']
    assert result['killed']==(1 if case=='timeout' else 0)
    assert result['manifest']==success
    assert result['selected']==(['ethernet.inf'] if success else [])
    assert not result['partial'] and not result['staging']
    if case=='missing_code':assert 'indisponible' in result['message']
    if case=='extract_failure':assert 'code 7' in result['message']


@pytest.mark.parametrize('case',['success','prepare_failure','driver_failure'])
def test_real_build_adds_network_infs_and_preserves_old_image_on_failure(tmp_path,case):
    source=tmp_path/'source';shutil.copytree(ROOT/'scripts',source)
    build=source/'Build-WinPE.ps1'
    # Only remove the Windows administrator requirement for this simulated ADK.
    build.write_text(build.read_text().replace('#requires -RunAsAdministrator\n',''))
    helper="""
function Get-AtelierWinPEHpDrivers {
 param($CacheRoot)
 if ('CASE' -eq 'prepare_failure') { throw 'HP pack unavailable' }
 return [pscustomobject]@{network_infs=@('network-first.inf','network-second.inf');softpaq='fixture'}
}
""".replace('CASE',case)
    (source/'WinPE-HPDrivers.ps1').write_text(helper)
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
function Mount-WindowsImage {param($ImagePath,$Index,$Path)}
function Add-WindowsPackage {param($Path,$PackagePath)}
function Add-WindowsDriver {
 [CmdletBinding()]param($Path,$Driver,[switch]$Recurse,[switch]$ForceUnsigned)
 if ($ForceUnsigned -or $Recurse) { throw 'Official network INFs must be individually validated by DISM' }
 if ('CASE' -eq 'driver_failure') { throw 'DISM rejected driver' }
 $global:atelierDriverTestAdded.Add($Driver)
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
    assert result['added']==(['network-first.inf','network-second.inf'] if case=='success' else [])
    assert result['saved']==result['marker']==result['imported']==(case=='success')
    assert result['discarded']==(case=='driver_failure')


@pytest.mark.parametrize('case',['fast_success','exit_7','timeout'])
def test_native_child_process_exit_and_arguments_with_spaces(tmp_path,case):
    """Use a real child, including Windows PowerShell 5.1 when running on Windows."""
    package=tmp_path/'HP extraction fixture.exe'
    destination=tmp_path/'extracted drivers with spaces';destination.mkdir()
    prelude=''
    powershell=PWSH
    if os.name=='nt':
        powershell=str(Path(os.environ['SystemRoot'])/'System32'/'WindowsPowerShell'/'v1.0'/'powershell.exe')
        if not Path(powershell).exists():pytest.skip('Windows PowerShell 5.1 required')
        code='''
using System;
using System.IO;
using System.Threading;
public class ExtractionFixture {
 public static int Main(string[] args) {
  if (args.Length!=4 || args[0]!="/s" || args[1]!="/e" || args[2]!="/f") return 91;
  File.WriteAllLines(Path.Combine(args[3],"arguments.txt"),args);
  Thread.Sleep(DELAY);
  return EXIT;
 }
}
'''.replace('DELAY','3000' if case=='timeout' else '0').replace('EXIT','7' if case=='exit_7' else '0')
        prelude="Add-Type -OutputType ConsoleApplication -OutputAssembly 'WORK/HP extraction fixture.exe' -TypeDefinition @'\n"+code+"\n'@\n"
    else:
        package.write_text('#!/bin/sh\n'
                           '[ "$#" -eq 4 ] && [ "$1" = /s ] && [ "$2" = /e ] && [ "$3" = /f ] || exit 91\n'
                           'printf "%s\\n" "$@" > "$4/arguments.txt"\n'+
                           ('exec sleep 3\n' if case=='timeout' else 'exit '+('7' if case=='exit_7' else '0')+'\n'))
        package.chmod(0o700)
    result=execute(tmp_path,prelude+r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/WinPE-HPDrivers.ps1'
$failed=$false;$message='';$runs=0
try {
 for ($i=0;$i -lt 3;$i++) {
  Invoke-AtelierWinPEHpExtraction -Package 'WORK/HP extraction fixture.exe' -Destination 'WORK/extracted drivers with spaces' -TimeoutSeconds 1
  $runs++
 }
} catch { $failed=$true;$message=$_.Exception.Message }
@{failed=$failed;message=$message;runs=$runs} | ConvertTo-Json -Compress
''',powershell=powershell)
    assert result['failed']==(case!='fast_success'),result
    assert result['runs']==(3 if case=='fast_success' else 0)
    assert (destination/'arguments.txt').read_text(encoding='utf-8-sig').splitlines()==['/s','/e','/f',str(destination)]
    if case=='exit_7':assert 'code 7' in result['message']
    if case=='timeout':assert 'trop longue' in result['message']
