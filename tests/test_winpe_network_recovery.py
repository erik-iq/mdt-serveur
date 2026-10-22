"""Startup recovery must target the injected I219 and préserve a working dock."""
import hashlib

import pytest

from test_winpe_intel_drivers import execute, PWSH

pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize('case',['success','dock','other_nic','no_config','bad_path','bad_hash','drvload_failure','initialize_failure','exception'])
def test_i219_retry_is_bounded_and_never_blocks_the_wizard(tmp_path,case):
    relative='Windows/System32/DriverStore/FileRepository/e1d.inf_amd64_0123456789abcdef/e1d.inf'
    inf=tmp_path/relative;inf.parent.mkdir(parents=True);inf.write_text('driver fixture')
    result=execute(tmp_path,r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/WinPE-NetworkRecovery.ps1'
$env:SystemRoot='WORK/Windows'
$script:calls=New-Object 'Collections.Generic.List[object]'
function Get-AtelierWinPERoot { return 'WORK' }
function Test-AtelierWinPEIPv4 { return ('CASE' -eq 'dock') }
function Test-AtelierI219Hardware { return ('CASE' -ne 'other_nic') }
function Invoke-AtelierWinPENetworkCommand {
 param($FilePath,$Arguments)
 $script:calls.Add(@{file=[IO.Path]::GetFileName($FilePath);arguments=$Arguments})
 if ('CASE' -eq 'exception') { throw 'native process failure' }
 if ('CASE' -eq 'drvload_failure' -and $FilePath -like '*drvload.exe') { return 5 }
 if ('CASE' -eq 'initialize_failure' -and $FilePath -like '*wpeutil.exe') { return 3 }
 return 0
}
$config=[pscustomobject]@{i219_recovery=[pscustomobject]@{inf='RELATIVE';sha256='HASH'}}
if ('CASE' -eq 'bad_path') { $config.i219_recovery.inf='../outside.inf' }
if ('CASE' -eq 'bad_hash') { $config.i219_recovery.sha256='not-a-matching-hash' }
if ('CASE' -eq 'no_config') { $config=[pscustomobject]@{} }
Initialize-AtelierI219Network -Config $config -LogPath 'WORK/log/recovery.json'
$log=$null
if (Test-Path 'WORK/log/recovery.json') { $log=Get-Content 'WORK/log/recovery.json' -Raw | ConvertFrom-Json }
@{calls=@($script:calls.ToArray());log=$log;continued=$true} | ConvertTo-Json -Depth 5 -Compress
'''.replace('CASE',case).replace('RELATIVE',relative).replace('HASH',hashlib.sha256(inf.read_bytes()).hexdigest()))
    assert result['continued']
    if case in {'dock','other_nic','no_config'}:
        assert result['calls']==[] and result['log'] is None
        return
    expected=2 if case in {'success','initialize_failure'} else 1 if case in {'drvload_failure','exception'} else 0
    assert len(result['calls'])==expected
    assert result['log']['stage']==('i219_retry' if case=='success' else 'i219_retry_failed')
    if expected:
        assert result['calls'][0]['file']=='drvload.exe'
        assert result['calls'][0]['arguments']=='"'+str(inf)+'"'
    if expected==2:
        assert result['calls'][1]['file']=='wpeutil.exe'
        assert result['calls'][1]['arguments']=='InitializeNetwork /NoWaitForNetwork'


@pytest.mark.parametrize('code',[0,7])
def test_owned_native_process_keeps_fast_child_exit_code(tmp_path,code):
    result=execute(tmp_path,r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/WinPE-NetworkRecovery.ps1'
$codes=@()
for ($i=0;$i -lt 3;$i++) {
 $codes+=Invoke-AtelierWinPENetworkCommand -FilePath 'PWSH' -Arguments '-NoProfile -NonInteractive -Command "exit CODE"'
}
@{codes=$codes} | ConvertTo-Json -Compress
'''.replace('PWSH',str(PWSH).replace("'","''")).replace('CODE',str(code)))
    assert result['codes']==[code]*3
