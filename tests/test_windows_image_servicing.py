"""Run the real PS orchestration while mocking DISM and the Microsoft network."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell required')


@pytest.mark.parametrize('case', ['success', 'source_changed', 'backup_corrupt', 'locked', 'mount_failure',
    'download_failure', 'package_tampered', 'package_failure', 'commit_failure', 'bad_package_state', 'discard_failure', 'no_target_edition',
    'reuse', 'up_to_date', 'new_update', 'tampered_cache', 'cancelled_cache', 'export_failure', 'wrong_export_edition'])
def test_source_and_backup_protected_and_partial_candidates_never_ready(tmp_path, case):
    runtime = tmp_path / 'fake-python.ps1'
    runtime.write_text(r'''
$script:LASTEXITCODE=0;$global:LASTEXITCODE=0
if ('CASE' -eq 'download_failure') { Write-Error 'Fixture Microsoft catalog connection failed';$global:LASTEXITCODE=1;return }
$output=$args[[array]::IndexOf($args,'--output')+1]
$file='WORK/update.msu';Set-Content -LiteralPath $file -Value 'fixture update'
$hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
if ('CASE' -eq 'package_tampered') { Set-Content -LiteralPath $file -Value 'tampered' }
@{groups=@(@{kind='os';id=$(if($global:catalogNew){'new-update-id'}else{'fixture-update-id'});kb='KB5127648';title='Fixture cumulative';target_build='26300.9711';target_path=$file;files=@(@{path=$file;sha256=$hash})})} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $output
'''.replace('CASE', case).replace('WORK', str(tmp_path)))
    script = tmp_path / 'run.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/Windows-ImageServicing.ps1'
$source='WORK/source.wim';[IO.File]::WriteAllText($source,'original immutable WIM fixture')
$expected=(Get-FileHash $source -Algorithm SHA256).Hash
$root='WORK/maintenance with spaces'
$script:commands=New-Object Collections.Generic.List[string]
function Get-WindowsImage { param($ImagePath,$Index)
 $reduced=(Split-Path $ImagePath -Leaf) -eq 'candidate.wim'
 if ($Index) {
  $edition=if ('CASE' -eq 'no_target_edition') {'Education'} elseif ($reduced) {@('Core','Professional')[$Index-1]} else {@('Core','CoreN','CoreSingleLanguage','Professional','ProfessionalN','Education')[$Index-1]}
  if ($reduced -and 'CASE' -eq 'wrong_export_edition') { $edition='Education' }
  return [pscustomobject]@{ImageIndex=$Index;ImageName=('Windows '+$edition);EditionId=$edition;Architecture=9;Version='10.0.26300.1'}
 }
 return @(1..$(if($reduced){2}else{6}) | ForEach-Object { [pscustomobject]@{ImageIndex=$_} })
}
function Get-AtelierServicingDism { param($Build) return 'mock-dism' }
function Get-PSDrive { param($Name) return $null }
function Get-AtelierOfflineWindowsVersion { param($MountPath) return [pscustomobject]@{family='11';release='26H2';build=26300;dotnet='4.8.1'} }
function Get-WindowsPackage { param($Path) return [pscustomobject]@{PackageName='Rollup';PackageState=$(if ('CASE' -eq 'bad_package_state') {'PartiallyInstalled'} else {'InstallPending'});ReleaseType='SecurityUpdate';InstallTime=[datetime]::UtcNow} }
function Invoke-AtelierImageDism { param($Executable,[string[]]$Arguments,$LogPath)
 $script:commands.Add(($Arguments -join '|'))
 if ($Arguments -contains '/Export-Image') {
  if ('CASE' -eq 'export_failure') { throw 'Mock export failed' }
  $destination=($Arguments | Where-Object { $_ -like '/DestinationImageFile:*' }).Substring(22)
  Add-Content -LiteralPath $destination -Value 'exported'
 }
 if ($Arguments -contains '/Discard' -and 'CASE' -eq 'discard_failure') { throw 'Mock discard failed' }
 if ($Arguments -contains '/Mount-Image' -and 'CASE' -eq 'mount_failure') { throw 'Mock mount failed' }
 if ($Arguments -contains '/Add-Package' -and 'CASE' -in @('package_failure','discard_failure')) { throw 'Mock package failed' }
 if ($Arguments -contains '/Commit' -and 'CASE' -eq 'commit_failure') { throw 'Mock commit failed' }
 if ($Arguments -contains '/Add-Package') {
  $image=($Arguments | Where-Object { $_ -like '/Image:*' }).Substring(7)
  $candidate=Join-Path (Split-Path $image -Parent) 'candidate.wim'
  Add-Content -LiteralPath $candidate -Value 'updated'
 }
 return 0
}
if ('CASE' -eq 'source_changed') { Add-Content $source 'changed externally' }
New-Item -ItemType Directory -Path $root -Force | Out-Null
$held=$null
if ('CASE' -eq 'locked') { $held=[IO.File]::Open((Join-Path $root 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
if ('CASE' -eq 'backup_corrupt') {
 New-Item -ItemType Directory -Path (Join-Path $root 'backups') | Out-Null
 Set-Content (Join-Path (Join-Path $root 'backups') ($expected.ToLowerInvariant()+'.wim')) 'corrupt'
}
$failed=$false;$message='';$result=$null
try {
 $result=New-AtelierServicedWindowsImage -ImagePath $source -ExpectedHash $expected -WorkRoot $root -PythonPath 'WORK/fake-python.ps1' -SourceAssetId 'fixture'
 if ('CASE' -in @('reuse','up_to_date','new_update','tampered_cache','cancelled_cache')) {
  $script:commands.Clear()
  if ('CASE' -eq 'new_update') { $global:catalogNew=$true }
  if ('CASE' -eq 'tampered_cache') { Set-Content -LiteralPath $result.candidate_path -Value 'corrupt candidate' }
  if ('CASE' -eq 'cancelled_cache') { $result.status='cancelled';Write-AtelierServicingJson $result (Join-Path (Split-Path $result.candidate_path -Parent) 'report.json') }
  $nextSource=if ('CASE' -eq 'up_to_date') {$result.candidate_path}else{$source}
  $nextHash=(Get-FileHash $nextSource -Algorithm SHA256).Hash
  $second=New-AtelierServicedWindowsImage -ImagePath $nextSource -ExpectedHash $nextHash -WorkRoot $root -PythonPath 'WORK/fake-python.ps1' -SourceAssetId 'fixture'
 }
}
catch { $failed=$true;$message=$_.Exception.Message }
finally { if ($held) { $held.Dispose() } }
$reports=@(Get-ChildItem $root -Recurse -Filter report.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
@{failed=$failed;message=$message;source=(Get-Content $source -Raw);second=$second;commands=@($script:commands.ToArray());reports=$reports;backups=@(Get-ChildItem $root -Recurse -Filter '*.wim' | Where-Object { $_.Directory.Name -eq 'backups' } | ForEach-Object { Get-Content $_.FullName -Raw });candidates=@(Get-ChildItem $root -Recurse -Filter 'candidate.wim').Count} | ConvertTo-Json -Depth 20 -Compress
'''.replace('CASE', case).replace('PROJECT', str(ROOT)).replace('WORK', str(tmp_path)), encoding='utf-8-sig')
    run = subprocess.run([PWSH, '-NoProfile', '-File', str(script)], capture_output=True, text=True, timeout=60)
    assert run.returncode == 0, run.stdout + run.stderr
    result = json.loads(run.stdout.splitlines()[-1])
    successes = {'success', 'reuse', 'up_to_date', 'new_update', 'tampered_cache', 'cancelled_cache'}
    assert result['failed'] == (case not in successes), result
    assert 'updated' not in result['source']
    if case != 'source_changed':
        assert result['source'] == 'original immutable WIM fixture'
    if case not in {'backup_corrupt', 'locked', 'source_changed', 'no_target_edition'}:
        assert result['backups'] == ['original immutable WIM fixture']
    if case in {'reuse', 'up_to_date'}:
        assert result['commands'] == [] and result['candidates'] == 1
        assert result['second']['status'] == ('up_to_date' if case == 'up_to_date' else 'ready_for_test')
        if case == 'reuse': assert result['second']['reused']
    elif case in successes:
        report = result['reports'][-1]
        if case != 'success':
            assert result['candidates'] == 2
            report = result['second']
        assert report['status'] == 'ready_for_test'
        assert [(i['source_index'], i['index']) for i in report['indexes']] == [(1, 1), (4, 2)]
        assert {i['edition'] for i in report['selected_indexes']} == {'Core', 'Professional'}
        assert {i['index'] for i in report['skipped_indexes']} == {2, 3, 5, 6}
        assert report['compression'] == 'fast'
        assert {'backup','export_fast','catalog_download','commit','verify_hash'} <= {t['stage'] for t in report['timings']}
        exports = [c for c in result['commands'] if '/Export-Image' in c]
        assert len(exports) == 2 and all('/Compress:fast' in c for c in exports)
        assert '/SourceIndex:1|' in exports[0] and '/SourceIndex:4|' in exports[1]
        mounts = [c for c in result['commands'] if '/Mount-Image' in c]
        assert len(mounts) == 2 and '/Index:1|' in mounts[0] and '/Index:2|' in mounts[1]
        if case == 'success': assert result['candidates'] == 1
        assert all('/IgnoreCheck' not in command and '/Online' not in command for command in result['commands'])
    elif case == 'no_target_edition':
        assert 'Aucun index Windows Famille' in result['message']
        assert not result['commands'] and not result['backups'] and not result['reports']
    elif result['reports']:
        assert result['reports'][0]['status'] == ('failed_cleanup_required' if case == 'discard_failure' else 'failed')
        assert result['candidates'] == (1 if case == 'discard_failure' else 0)
        if case == 'download_failure':
            assert 'Fixture Microsoft catalog connection failed' in result['message']
            assert 'catalog-index-1.log' in result['reports'][0]['error']
            logs = list((tmp_path / 'maintenance with spaces' / 'runs').glob('*/catalog-index-1.log'))
            assert len(logs) == 1 and 'Fixture Microsoft catalog connection failed' in logs[0].read_text(encoding='utf-8-sig')
            context = json.loads(logs[0].with_name('catalog-input-index-1.json').read_text(encoding='utf-8-sig'))
            assert context == {'family': '11', 'release': '26H2', 'architecture': 'x64', 'dotnet': '4.8.1', 'build': 26300}


@pytest.mark.parametrize('case', ['schedule', 'run_now', 'already_running', 'register_failure', 'start_failure'])
def test_monthly_task_only_prepares_and_never_interrupts_running_dism(tmp_path, case):
    local = tmp_path / 'scripts'
    local.mkdir()
    for name in ('Console-Installation.ps1', 'Windows-ImageServicing.ps1'):
        shutil.copyfile(ROOT / 'scripts' / name, local / name)
    enable = (ROOT / 'scripts' / 'Enable-WindowsImageMaintenance.ps1').read_text().replace('#requires -RunAsAdministrator\n', '')
    (local / 'Enable-WindowsImageMaintenance.ps1').write_text(enable)
    install = tmp_path / 'console & atelier'
    (install / 'scripts').mkdir(parents=True)
    (install / 'scripts' / 'Update-WindowsImage.ps1').write_text('# fixture')
    (install / 'data-runtime.json').write_text(json.dumps({'data_dir': str(tmp_path / 'data')}))
    script = tmp_path / 'schedule.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop';$env:SystemRoot='WORK/windows'
$global:AtelierTestScheduleXml='';$global:AtelierTestScheduleStarts=0
function icacls.exe { $global:LASTEXITCODE=0 }
function Get-ScheduledTask { param($TaskName,$ErrorAction)
 if ('CASE' -eq 'already_running') { return [pscustomobject]@{State='Running';Actions=@()} }
 return $null
}
function Register-ScheduledTask {
 [CmdletBinding()]param($TaskName,$Xml,[switch]$Force)
 $global:AtelierTestScheduleXml=$Xml
 if ('CASE' -eq 'register_failure') { Write-Error 'Mock task registration failed';return }
}
function Start-ScheduledTask {
 [CmdletBinding()]param($TaskName)
 $global:AtelierTestScheduleStarts++
 if ('CASE' -eq 'start_failure') { Write-Error 'Mock task start failed' }
}
$failed=$false;$message=''
# Exercise CIM-style nonterminating errors even when the caller continues.
try { & 'WORK/scripts/Enable-WindowsImageMaintenance.ps1' -InstallPath 'INSTALL' -RunNow:('CASE' -in @('run_now','register_failure','start_failure')) -ErrorAction Continue }
catch { $failed=$true;$message=$_.Exception.Message }
@{failed=$failed;message=$message;xml=$global:AtelierTestScheduleXml;starts=$global:AtelierTestScheduleStarts} | ConvertTo-Json -Compress
'''.replace('CASE', case).replace('WORK', str(tmp_path)).replace('INSTALL', str(install)))
    run = subprocess.run([PWSH, '-NoProfile', '-File', str(script)], capture_output=True, text=True, timeout=45)
    assert run.returncode == 0, run.stdout + run.stderr
    result = json.loads(run.stdout.splitlines()[-1])
    assert result['failed'] == (case in {'already_running', 'register_failure', 'start_failure'}), result
    if case != 'already_running':
        from xml.etree import ElementTree as ET
        task = ET.fromstring(result['xml'])
        ns = {'t': 'http://schemas.microsoft.com/windows/2004/02/mit/task'}
        principal = task.find('.//t:Principal', ns)
        assert principal.find('t:UserId', ns).text == 'S-1-5-18'
        assert principal.find('t:LogonType', ns) is None
        assert principal.find('t:RunLevel', ns).text == 'HighestAvailable'
        assert task.find('.//t:ScheduleByMonth/t:DaysOfMonth/t:Day', ns).text == '15'
        assert len(task.find('.//t:Months', ns)) == 12
        assert task.find('.//t:MultipleInstancesPolicy', ns).text == 'IgnoreNew'
        assert task.find('.//t:ExecutionTimeLimit', ns).text == 'PT0S'
        assert 'Publish' not in task.find('.//t:Arguments', ns).text
        assert str(install) in task.find('.//t:Arguments', ns).text
        assert result['starts'] == (case in {'run_now', 'start_failure'})
    else:
        assert not result['xml'] and not result['starts']
    if result['failed']:
        assert 'Maintenance Windows planifiée' not in run.stdout
    if case == 'register_failure':
        assert 'Mock task registration failed' in result['message']
    if case == 'start_failure':
        assert 'Mock task start failed' in result['message']
