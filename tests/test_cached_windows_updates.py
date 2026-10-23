"""Installation native simulée, checkpoints, redémarrage et compatibilité des KB."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import pytest
ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell requis')


@pytest.mark.parametrize('case',['success','already_installed','wrong_context','install_failure','install_failure552','download_failure','lost_process','bad_build_after_boot','checkpoint_gap'])
def test_no_wua_scan_and_no_false_success_without_install_and_boot(tmp_path,case):
    (tmp_path/'reporting.json').write_text(json.dumps({'id':'1f99fd15-f6ea-48ed-ab9c-0d8d7c27ad8f','server_url':'https://atelier.test','token':'fixture'}))
    script=r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/Unattend.ps1'
. 'PROJECT/scripts/Client-KBUpdates.ps1'
$global:boot='2026-10-22T06:00:00Z';$global:package=$false;$global:installed=$false
function Get-AtelierKbContext {return @{family='11';release='26H2';architecture='x64';dotnet='4.8.1';build=26300}}
function Get-AtelierKbBoot {return $global:boot}
function Get-AtelierKbBuild {return [version]$(if($global:installed -and 'CASE' -ne 'bad_build_after_boot'){'10.0.26300.9711'}else{'10.0.26300.9457'})}
function Get-HotFix { [CmdletBinding()]param();if ('CASE' -eq 'already_installed') {[pscustomobject]@{HotFixID='KB5127648'}} }
function Get-WindowsPackage { [CmdletBinding()]param([switch]$Online);if($global:package){[pscustomobject]@{PackageName='Package_for_RollupFix_fixture';PackageState=$(if($global:installed){'Installed'}else{'InstallPending'})}} }
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 $context=Get-AtelierKbContext
 if ('CASE' -eq 'wrong_context') {$context.architecture='arm64'}
 [pscustomobject]@{id='1f99fd15-f6ea-48ed-ab9c-0d8d7c27ad8f';status='ready';context=[pscustomobject]$context;groups=@([pscustomobject]@{kind='os';kb='KB5127648';title='Correctif simulé';target_build='26300.9711';files=@([pscustomobject]@{filename='windows11.0-kb5127648-x64.msu';sha256=('a'*64);size=10;url='/api/windows/fixture'})})}
}
function Get-AtelierKbFile {
 param($Config,$File,$Destination,$OnProgress)
 if ('CASE' -eq 'download_failure') {throw 'Copie incomplète'}
 Set-Content $Destination 'fixture'
}
function Invoke-AtelierKbInstall {
 param($Directory,$LogPath,$OnProgress,$State,$StatePath)
 $checkpoint=Get-Content 'DATA/windows-kb-result.json' -Raw|ConvertFrom-Json
 if ($checkpoint.status -ne 'installing') {throw 'Checkpoint absent avant installation'}
 Add-Content 'DATA/native-calls' 'install'
 if ('CASE' -eq 'lost_process') {throw 'Processus encore actif'}
 $global:package=$true
 if ('CASE' -eq 'install_failure') {return 5}
 if ('CASE' -eq 'install_failure552') {Set-Content $LogPath 'Error: 0x80070228';return 552}
 return 3010
}
function Invoke-AtelierWindowsUpdates {throw 'Recherche Windows Update interdite'}
$first=Invoke-AtelierCachedWindowsUpdates -DataPath 'DATA'
$first|ConvertTo-Json -Depth 12|Set-Content 'DATA/first.json'
if ('CASE' -in @('success','bad_build_after_boot','checkpoint_gap')) {
 if ('CASE' -eq 'checkpoint_gap') {$checkpoint=Get-Content 'DATA/windows-kb-result.json' -Raw|ConvertFrom-Json;$checkpoint.status='running';$checkpoint|ConvertTo-Json -Depth 18|Set-Content 'DATA/windows-kb-result.json'}
 $same=Invoke-AtelierCachedWindowsUpdates -DataPath 'DATA'
 if ($same.status -ne 'reboot_pending') {throw 'Redémarrage consommé trop tôt'}
 $global:boot='2026-10-22T07:00:00Z';$global:installed=$true
 $last=Invoke-AtelierCachedWindowsUpdates -DataPath 'DATA'
 $last|ConvertTo-Json -Depth 12|Set-Content 'DATA/last.json'
}
'''.replace('PROJECT',str(ROOT)).replace('DATA',str(tmp_path)).replace('CASE',case)
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    proc=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert proc.returncode==0,proc.stderr
    read=lambda name:json.loads((tmp_path/name).read_text(encoding='utf-8-sig'))
    first=read('first.json')
    if case in ('success','checkpoint_gap'):
        assert first['status']=='reboot_pending' and first['entries'][0]['exit_code']==3010
        assert read('last.json')['status']=='completed'
        assert read('last.json')['entries'][0]['status']=='completed'
        assert (tmp_path/'native-calls').read_text().splitlines()==['install']
    elif case=='already_installed':assert first['status']=='completed' and not (tmp_path/'native-calls').exists()
    elif case=='install_failure552':
        assert first['status']=='needs_attention' and first['entries'][0]['exit_code']==552
        assert '0X80070228' in first['message']
        assert first['entries'][0]['diagnostic']
    elif case=='lost_process':assert first['status']=='installing'
    elif case=='bad_build_after_boot':assert read('last.json')['status']=='needs_attention'
    else:assert first['status']=='needs_attention'


def test_net_then_windows_resume_across_two_reboots_without_reinstall(tmp_path):
    (tmp_path/'reporting.json').write_text(json.dumps({'id':'1f99fd15-f6ea-48ed-ab9c-0d8d7c27ad8f','server_url':'https://atelier.test','token':'fixture'}))
    script=r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/Unattend.ps1'
. 'PROJECT/scripts/Client-KBUpdates.ps1'
$global:boot=[datetime]'2026-10-22T06:00:00Z';$global:done=@();$global:final=$false
function Get-AtelierKbContext {return @{family='11';release='26H2';architecture='x64';dotnet='4.8.1';build=26300}}
function Get-AtelierKbBoot {return $global:boot.ToString('o')}
function Get-AtelierKbBuild {return [version]$(if($global:final){'10.0.26300.9711'}else{'10.0.26300.9457'})}
function Get-HotFix { [CmdletBinding()]param() }
function Get-WindowsPackage { [CmdletBinding()]param([switch]$Online);foreach ($kb in $global:done) {[pscustomobject]@{PackageName=$kb;PackageState='Installed'}} }
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 [pscustomobject]@{id='1f99fd15-f6ea-48ed-ab9c-0d8d7c27ad8f';status='ready';context=[pscustomobject](Get-AtelierKbContext);groups=@(
 [pscustomobject]@{kind='net';kb='KB5127694';title='.NET';target_build='';files=@([pscustomobject]@{filename='net.msu'})},
 [pscustomobject]@{kind='os';kb='KB5127648';title='Windows';target_build='26300.9711';files=@([pscustomobject]@{filename='os.msu'})})}
}
function Get-AtelierKbFile {param($Config,$File,$Destination,$OnProgress);Set-Content $Destination 'fixture'}
function Invoke-AtelierKbInstall {param($Directory,$LogPath,$OnProgress,$State,$StatePath);Add-Content 'DATA/calls' $State.active_kb;$global:done+=@($State.active_kb);return 3010}
$first=Invoke-AtelierCachedWindowsUpdates -DataPath 'DATA'
if ($first.status -ne 'reboot_pending') {throw $first.message}
$global:boot=$global:boot.AddMinutes(5)
$second=Invoke-AtelierCachedWindowsUpdates -DataPath 'DATA'
if ($second.status -ne 'reboot_pending') {throw $second.message}
$global:boot=$global:boot.AddMinutes(5);$global:final=$true
$third=Invoke-AtelierCachedWindowsUpdates -DataPath 'DATA'
$third|ConvertTo-Json -Depth 18|Set-Content 'DATA/final.json'
'''.replace('PROJECT',str(ROOT)).replace('DATA',str(tmp_path))
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    proc=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert proc.returncode==0,proc.stderr
    result=json.loads((tmp_path/'final.json').read_text(encoding='utf-8-sig'))
    assert result['status']=='completed' and all(e['status']=='completed' for e in result['entries'])
    assert (tmp_path/'calls').read_text().splitlines()==['KB5127694','KB5127648']


@pytest.mark.skipif(os.name=='nt',reason='Exécutable natif Linux de simulation')
@pytest.mark.parametrize('mode',['target','missing','ambiguous'])
def test_dism_uses_exact_target_msu_preserves_checkpoints_and_captures_output(tmp_path,mode):
    system=tmp_path/'system';(system/'System32').mkdir(parents=True)
    executable=system/'System32/dism.exe'
    executable.write_text('''#!/usr/bin/env python3
import pathlib,sys,json
pathlib.Path(__file__+'.args').write_text(json.dumps(sys.argv[1:]))
print('DISM fixture output')
print('DISM fixture error output',file=sys.stderr)
''');executable.chmod(0o755)
    packages=tmp_path/'packages';packages.mkdir()
    (packages/'windows11.0-kb5043080-x64.msu').write_bytes(b'checkpoint')
    if mode!='missing':(packages/'windows11.0-kb5127648-x64.msu').write_bytes(b'target')
    if mode=='ambiguous':(packages/'windows11.0-kb5127648-x64_rev2.msu').write_bytes(b'other')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/Unattend.ps1'
. 'PROJECT/scripts/Client-KBUpdates.ps1'
$env:SystemRoot='SYSTEM'
$state=@{status='installing';active_kb='KB5127648';entries=@()}
$failed=$false;$code=$null
try {$code=Invoke-AtelierKbInstall -Directory 'PACKAGES' -LogPath 'DATA/kb-KB5127648.log' -OnProgress {param($Message)} -State $state -StatePath 'DATA/state.json'}catch{$failed=$true}
@{failed=$failed;code=$code;state=$state}|ConvertTo-Json -Depth 8|Set-Content 'DATA/out.json'
'''.replace('PROJECT',str(ROOT)).replace('SYSTEM',str(system)).replace('PACKAGES',str(packages)).replace('DATA',str(tmp_path)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=20)
    assert run.returncode==0,run.stderr
    value=json.loads((tmp_path/'out.json').read_text('utf-8-sig'))
    if mode=='target':
        assert value['code']==0 and not value['failed'],value
        args=json.loads(Path(str(executable)+'.args').read_text())
        assert '/PackagePath:'+str(packages/'windows11.0-kb5127648-x64.msu') in args
        assert not any(arg=='/PackagePath:'+str(packages) for arg in args)
        console=(tmp_path/'kb-KB5127648-console.log').read_text('utf-8-sig')
        assert 'DISM fixture output' in console and 'DISM fixture error output' in console
    else:
        assert value['failed'] and not Path(str(executable)+'.args').exists()
    assert (packages/'windows11.0-kb5043080-x64.msu').read_bytes()==b'checkpoint'
