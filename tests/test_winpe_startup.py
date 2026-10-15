"""Exercise startup failures and privacy without WinForms, DISM or a real boot."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell is required for startup execution tests')


def invoke(script):
    return subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-NonInteractive',
                           '-ExecutionPolicy', 'Bypass', '-File', str(script)],
                          capture_output=True, text=True, timeout=30)


def boot_fixture(tmp_path):
    for name in ('Launch.ps1', 'WinPE-Session.ps1'):
        shutil.copyfile(ROOT / 'scripts' / name, tmp_path / name)
    # Replace only the native input-language operation. The real launcher,
    # configuration loading, error handling and journal writing still execute.
    with (tmp_path / 'WinPE-Session.ps1').open('a', encoding='utf-8') as helper:
        helper.write('\nfunction Set-AtelierOperatorKeyboard { param($Layout) }\n')
    (tmp_path / 'config.json').write_text(json.dumps({
        'server_url': 'https://192.168.99.250', 'boot_release': 'FR-REPRISE-1',
        'winpe_keyboard_layout': '040c:0000040c'}), encoding='utf-8')
    return tmp_path / 'Launch.ps1'


def entries(tmp_path):
    return [json.loads(line) for line in (tmp_path / 'Logs' / 'startup.log')
            .read_text(encoding='utf-8-sig').splitlines()]


def test_wizard_failure_is_reported_without_secrets_and_next_launch_succeeds(tmp_path):
    launcher = boot_fixture(tmp_path)
    secrets = 'SMB-password Agent-token Boot-code'
    (tmp_path / 'Wizard.ps1').write_text("throw '" + secrets + "'", encoding='utf-8-sig')
    failed = invoke(launcher)
    assert failed.returncode == 1, failed.stdout + failed.stderr
    assert 'Echec du lancement' in failed.stdout
    first_run = entries(tmp_path)
    assert [event['stage'] for event in first_run] == [
        'Starting', 'ConfigurationReady', 'KeyboardReady', 'CertificateReady', 'OpeningWizard', 'Failed']
    assert first_run[-1]['script'] == 'Wizard.ps1'
    assert first_run[-1]['line'] == 1
    for secret in secrets.split():
        assert secret not in json.dumps(first_run)

    (tmp_path / 'Wizard.ps1').write_text("Write-Output 'Wizard test completed'", encoding='utf-8-sig')
    retried = invoke(launcher)
    assert retried.returncode == 0, retried.stdout + retried.stderr
    assert entries(tmp_path)[-1]['stage'] == 'Closed'
    assert sum(event['stage'] == 'Starting' for event in entries(tmp_path)) == 2


def test_invalid_configuration_stops_before_opening_wizard(tmp_path):
    launcher = boot_fixture(tmp_path)
    (tmp_path / 'config.json').write_text('{invalid json', encoding='utf-8')
    (tmp_path / 'Wizard.ps1').write_text("throw 'Should never open'", encoding='utf-8-sig')
    result = invoke(launcher)
    assert result.returncode == 1
    assert [event['stage'] for event in entries(tmp_path)] == ['Starting', 'Failed']


def test_keyboard_failure_leaves_wizard_accessible(tmp_path):
    launcher = boot_fixture(tmp_path)
    with (tmp_path / 'WinPE-Session.ps1').open('a', encoding='utf-8') as helper:
        helper.write("\nfunction Set-AtelierOperatorKeyboard { param($Layout) throw 'Unavailable layout' }\n")
    (tmp_path / 'Wizard.ps1').write_text("Write-Output 'Wizard test completed'", encoding='utf-8-sig')
    result = invoke(launcher)
    assert result.returncode == 0, result.stdout + result.stderr
    assert [event['stage'] for event in entries(tmp_path)] == [
        'Starting', 'ConfigurationReady', 'KeyboardFailed', 'CertificateReady', 'OpeningWizard', 'Closed']


def test_error_record_message_details_and_invocation_are_not_logged(tmp_path):
    helper = str(ROOT / 'scripts' / 'WinPE-Session.ps1').replace("'", "''")
    journal = str(tmp_path / 'startup.log').replace("'", "''")
    script = tmp_path / 'verify.ps1'
    script.write_text("$ErrorActionPreference='Stop'\n. '" + helper + "'\n" + """
try {
    $failure = New-Object System.Management.Automation.ErrorRecord(
        (New-Object System.Exception('password-in-message')),
        'agent-token-in-error-id', [System.Management.Automation.ErrorCategory]::InvalidData,
        'boot-code-in-target')
    $failure.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('secret-in-error-details')
    throw $failure
} catch {
    Write-AtelierBootEvent -Path '""" + journal + "' -Stage Failed -Failure $_\n}\n", encoding='utf-8-sig')
    result = invoke(script)
    assert result.returncode == 0, result.stdout + result.stderr
    event = json.loads((tmp_path / 'startup.log').read_text(encoding='utf-8-sig'))
    assert set(event) == {'utc', 'stage', 'type', 'script', 'line'}
    for secret in ('password-in-message', 'agent-token-in-error-id', 'boot-code-in-target', 'secret-in-error-details'):
        assert secret not in json.dumps(event)
