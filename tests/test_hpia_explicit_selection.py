"""Regression: /Action:Install returned Analyze Action List with exit zero."""
import hashlib
import json
from pathlib import Path

import pytest

from test_hpia_generic_reference import ROOT, PWSH, run_ps

pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell required')


@pytest.mark.parametrize('case', ['selected_success', 'selected_failure', 'partial_results', 'still_analysis', 'not_ssm', 'unknown_result', 'numeric_csv'])
def test_single_explicit_retry_only_after_proven_analysis_and_for_ssm_recommendations(tmp_path, case):
    program = tmp_path / 'Program Files'
    exe = program / 'AtelierPXE/Tools/HPImageAssistant/HPImageAssistant.exe'
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b'HP fixture never executed')
    data = tmp_path / 'data'
    data.mkdir()
    (data / 'ready-tools.json').write_text(json.dumps([{'path': str(exe), 'sha256': hashlib.sha256(exe.read_bytes()).hexdigest()}]))
    result = run_ps(tmp_path, r'''
$ErrorActionPreference='Stop';$env:ProgramFiles='WORK/Program Files'
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);return [pscustomobject]@{Manufacturer='HP'}}
function Get-Process {param($Name);return }
function Get-AuthenticodeSignature {param($LiteralPath);return [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=HP Inc.'}}}
. 'PROJECT/scripts/HP-ImageAssistant.ps1'
$script:calls=0;$script:ids=@()
function Invoke-AtelierHpiaProcess {
 param($Executable,$Arguments,$Directory,$ResultPath,$State,$OnProgress,$TimeoutSeconds)
 $script:calls++
 $fixture=Get-Content 'PROJECT/tests/fixtures/hpia-generic-analysis.json' -Raw | ConvertFrom-Json
 foreach ($item in $fixture.HPIA.Recommendations) { $item | Add-Member NoteProperty SSMCompliant $('CASE' -ne 'not_ssm') }
 if ('CASE' -eq 'unknown_result') { $fixture.HPIA.HPIAOperation='Unknown';$fixture.HPIA.LastOperation='Unknown' }
 if ($Arguments -like '*/Force*') { throw 'Force is forbidden' }
 if ($Arguments -like '*/AutoReport*' -or $Arguments -notlike '*/Action:Install*' -or $Arguments -notlike '*/InstallType:AutoInstallable*') { throw 'Installation must not be replaced by the reporting operation' }
 if ($script:calls -eq 2) {
  $list=[regex]::Match($Arguments,'/SPList:"([^"]+)"')
  if (-not $list.Success) { throw 'An explicit HP SPList is required' }
  $script:ids=@(Get-Content -LiteralPath $list.Groups[1].Value)
  if (@($script:ids | Where-Object { $_ -notmatch '^[0-9]{4,8}$' }).Count -or $script:ids.Count -ne 11) { throw 'SPList contains unrelated or invalid IDs' }
  if ('CASE' -ne 'still_analysis') {
   $fixture.HPIA.HPIAOperation='Analyze Action Install';$fixture.HPIA.LastOperation='EndInstall'
   foreach ($item in $fixture.HPIA.Recommendations) { $item.Remediation=[pscustomobject]@{ReturnCode=0;ReturnDescription='Applied fixture'} }
   if ('CASE' -eq 'selected_failure') { $fixture.HPIA.Recommendations[0].Remediation.ReturnCode=1603 }
   if ('CASE' -eq 'partial_results') { $fixture.HPIA.Recommendations[0].Remediation=[pscustomobject]@{} }
  }
 }
 $fixture | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Directory 'HPIA.json')
 if ('CASE' -eq 'numeric_csv') { 'SoftPaqID,Name,ReturnCode,AutoInstallable'+[Environment]::NewLine+'SP110344,Fixture,0,TRUE' | Set-Content (Join-Path $Directory 'SoftPaqReport.csv') }
 if ('CASE' -eq 'selected_failure' -and $script:calls -eq 2) { return 3020 }
 return 0
}
$first=Invoke-AtelierHpia -DataPath 'WORK/data' -ToolsPath 'WORK/IQ_'
$second=Invoke-AtelierHpia -DataPath 'WORK/data' -ToolsPath 'WORK/IQ_'
@{first=$first;calls=$script:calls;ids=$script:ids;second=$second} | ConvertTo-Json -Depth 12 -Compress
'''.replace('CASE', case))
    retried = case in {'selected_success', 'selected_failure', 'partial_results', 'still_analysis'}
    assert result['calls'] == (2 if retried else 1), result
    state = result['first']
    if retried:
        assert len(result['ids']) == 11
        assert '96954' in result['ids'] and '150742' in result['ids']
        assert state['initial_install_exit_code'] == 0
    if case == 'selected_success':
        assert len(state['packages']) == 11 and state['status'] == 'completed'
    elif case == 'selected_failure':
        assert state['status'] == 'needs_attention' and state['exit_code'] == 3020
    elif case == 'partial_results':
        assert state['status'] == 'needs_attention' and len(state['unconfirmed_softpaqs']) == 1
    elif case == 'still_analysis':
        assert state['status'] == 'needs_attention' and not state['packages']
    assert result['second']['status'] == state['status']
