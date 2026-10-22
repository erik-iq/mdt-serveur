"""Exécute the supervisor and real PowerShell background job with a fake downloader."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

import pytest

PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
ROOT=Path(__file__).resolve().parents[1]


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
@pytest.mark.parametrize('outcome',['completed','partial','failed','nonterminating','sensitive'])
def test_worker_serializes_selection_and_reports_child_result(tmp_path,outcome):
    install=tmp_path/'installed';(install/'scripts').mkdir(parents=True)
    data=tmp_path/'data';(data/'software-sync'/'job-results').mkdir(parents=True)
    (data/'software-sync'/'worker-key').write_text('private-worker-key')
    (install/'data-runtime.json').write_text(json.dumps({'data_dir':str(data),'port':12345}))
    identifier=str(uuid.uuid4());bundle=str(uuid.uuid4())
    child=install/'scripts'/'Sync-Applications.ps1'
    child.write_text('''param($InstallPath,$Packages,$BundleIds,$WebJobId,$WorkerId)
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Raw | ConvertFrom-Json
@{packages=@($Packages);bundles=@($BundleIds);id=$WebJobId;worker=$WorkerId}|ConvertTo-Json|Set-Content 'SÉLECTION'
if ('OUTCOME' -eq 'failed') { throw 'Fixture preflight failure' }
if ('OUTCOME' -eq 'nonterminating') { Write-Error 'Fixture nonterminating cause' -ErrorAction Continue;return }
if ('OUTCOME' -eq 'sensitive') { Write-Error 'Fixture Bearer private-worker-key and private-worker-key' -ErrorAction Continue;return }
$apps=@(@{package='vlc';status='updated'})
if ('OUTCOME' -eq 'partial') { $apps+=@{package='chrome';status='failed';message='Fixture rejected'} }
@{applications=$apps;bundles=@()} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path (Join-Path $config.data_dir 'software-sync/job-results') ($WebJobId + '.json'))
'''.replace('SÉLECTION',str(tmp_path/'selection.json')).replace('OUTCOME',outcome),encoding='utf-8-sig')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text('''$ErrorActionPreference='Stop'
$global:atelierTestFinished=$false;$global:atelierTestClaimed=$false
function Get-Command { param($Name,$ErrorAction);[pscustomobject]@{Source='fake-winget.exe'} }
function Start-Sleep {
    param($Seconds)
    if ($global:atelierTestFinished) { throw 'Fixture worker stopped after result' }
    Microsoft.PowerShell.Utility\\Start-Sleep -Milliseconds 40
}
function Invoke-RestMethod {
    param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec)
    if ($Headers.Authorization -ne 'Bearer private-worker-key') { throw 'Unexpected credential' }
    $payload=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
    if ($Uri.EndsWith('/worker/claim')) {
        if ($global:atelierTestClaimed) { throw 'Duplicate claim' }
        $global:atelierTestClaimed=$true
        return [pscustomobject]@{job=[pscustomobject]@{id='JOB';packages=@('vlc','chrome');bundle_ids=@('BUNDLE')}}
    }
    if ($Uri.EndsWith('/finish')) {
        $payload|ConvertTo-Json -Depth 10|Set-Content 'RESULT'
        $global:atelierTestFinished=$true
    }
    return @{accepted=$true}
}
try { & 'WORKER' -InstallPath 'INSTALL' } catch { if (-not $global:atelierTestFinished) { throw } }
'''.replace('JOB',identifier).replace('BUNDLE',bundle).replace('RESULT',str(tmp_path/'result.json')).replace('WORKER',str(ROOT/'scripts'/'Software-Worker.ps1')).replace('INSTALL',str(install)),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr+run.stdout
    selection=json.loads((tmp_path/'selection.json').read_text(encoding='utf-8-sig'))
    assert selection['packages']==['vlc','chrome'] and selection['bundles']==[bundle] and selection['id']==identifier
    result=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))
    assert result['status']==('failed' if outcome in ('nonterminating','sensitive') else outcome)
    if outcome=='failed': assert 'Fixture preflight failure' in result['message']
    if outcome=='nonterminating':
        assert 'Fixture nonterminating cause' in result['message']
        assert any('Fixture nonterminating cause' in line for line in result['results']['diagnostics'])
        assert 'Fixture nonterminating cause' in (data/'software-sync'/'worker.log').read_text(encoding='utf-8-sig')
    if outcome=='sensitive':
        assert 'private-worker-key' not in json.dumps(result)
        assert 'private-worker-key' not in (data/'software-sync'/'worker.log').read_text(encoding='utf-8-sig')
    if outcome=='partial': assert result['results']['applications'][1]['status']=='failed'
