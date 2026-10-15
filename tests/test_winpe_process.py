"""Windows regression checks for ADK batch invocation, without DISM or WDS."""

import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


pytestmark = pytest.mark.skipif(sys.platform != 'win32', reason='Requires Windows cmd.exe and Windows PowerShell 5.1')
BUILD_SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'Build-WinPE.ps1'


def ps_quote(path):
    return "'" + str(path).replace("'", "''") + "'"


@pytest.mark.parametrize(('environment_exit', 'copy_exit'), [(0, 0), (29, 0), (0, 37)])
def test_adk_batch_paths_environment_and_failure_codes(tmp_path, environment_exit, copy_exit):
    if not ctypes.windll.shell32.IsUserAnAdmin():
        pytest.skip('Build-WinPE.ps1 requires an administrator session')

    # Simulate the installed ADK in a separate child process. The actual Windows
    # command interpreter executes both batches; only the image cmdlets are mocks.
    program_files = tmp_path / 'Program Files (x86)'
    adk = program_files / 'Windows Kits' / '10' / 'Assessment and Deployment Kit'
    deployment_tools = adk / 'Deployment Tools'
    pe = adk / 'Windows Preinstallation Environment'
    packages = pe / 'amd64' / 'WinPE_OCs'
    deployment_tools.mkdir(parents=True)
    packages.mkdir(parents=True)
    output = tmp_path / 'WinPE output with spaces'
    copied = tmp_path / 'copype-invoked.txt'
    mounted = tmp_path / 'mount-invoked.txt'

    (deployment_tools / 'DandISetEnv.bat').write_bytes((
        '@echo off\r\n'
        'set "ATELIER_PXE_TEST_ADK_READY=ready"\r\n'
        f'exit /b {environment_exit}\r\n'
    ).encode('ascii'))
    (pe / 'copype.cmd').write_bytes((
        '@echo off\r\n'
        'if not "%ATELIER_PXE_TEST_ADK_READY%"=="ready" exit /b 41\r\n'
        'if not "%~1"=="amd64" exit /b 42\r\n'
        'if not "%~2"=="%ATELIER_PXE_TEST_OUTPUT%" exit /b 43\r\n'
        'echo invoked>"%ATELIER_PXE_TEST_COPY_MARKER%"\r\n'
        f'if not "{copy_exit}"=="0" exit /b {copy_exit}\r\n'
        'mkdir "%~2\\media\\sources"\r\n'
        'mkdir "%~2\\mount\\Windows\\System32"\r\n'
        'type nul>"%~2\\media\\sources\\boot.wim"\r\n'
        'exit /b 0\r\n'
    ).encode('ascii'))

    wrapper = tmp_path / 'invoke-build.ps1'
    wrapper.write_text(f"""
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
function Mount-WindowsImage {{
    param($ImagePath, $Index, $Path)
    Set-Content -LiteralPath {ps_quote(mounted)} -Value 'mounted'
}}
function Add-WindowsPackage {{ param($Path, $PackagePath) }}
function Dismount-WindowsImage {{ param($Path, [switch]$Save, [switch]$Discard) }}
& {ps_quote(BUILD_SCRIPT)} -ServerUrl 'https://192.168.99.250' -OutputPath {ps_quote(output)}
""", encoding='utf-8-sig')
    child_environment = os.environ.copy()
    child_environment['ProgramFiles(x86)'] = str(program_files)
    child_environment.pop('ATELIER_PXE_TEST_ADK_READY', None)
    child_environment['ATELIER_PXE_TEST_OUTPUT'] = str(output)
    child_environment['ATELIER_PXE_TEST_COPY_MARKER'] = str(copied)
    powershell = Path(os.environ['SystemRoot']) / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'powershell.exe'
    result = subprocess.run(
        [str(powershell), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(wrapper)],
        env=child_environment, capture_output=True, timeout=60,
    )
    diagnostics = (result.stdout + result.stderr).decode('utf-8', errors='replace')

    if environment_exit or copy_exit:
        assert result.returncode != 0, diagnostics
        assert f'code {environment_exit or copy_exit}' in diagnostics, diagnostics
        assert copied.exists() == (environment_exit == 0)
        assert not mounted.exists(), diagnostics
        return

    assert result.returncode == 0, diagnostics
    assert copied.exists() and mounted.exists(), diagnostics
    assert (output / 'media' / 'sources' / 'boot.wim').exists()
    assert (output / 'mount' / 'Atelier' / 'Deploy.ps1').exists()
    assert (output / 'mount' / 'Atelier' / 'Launch.ps1').exists()
    system32 = output / 'mount' / 'Windows' / 'System32'
    assert 'atelier.cmd' in (system32 / 'startnet.cmd').read_text()
    assert 'X:\\Atelier\\Launch.ps1' in (system32 / 'atelier.cmd').read_text()
    assert '-STA' in (system32 / 'atelier.cmd').read_text()
    menu_bytes = (system32 / 'atelier.cmd').read_bytes()
    assert b'\r\n' in menu_bytes and b'\n' not in menu_bytes.replace(b'\r\n', b'')
    assert (output / 'mount' / 'Atelier' / 'WinPE-Session.ps1').exists()
    assert (output / 'mount' / 'Atelier' / 'Partitions.ps1').exists()
    configuration = json.loads((output / 'mount' / 'Atelier' / 'config.json').read_text(encoding='utf-8-sig'))
    assert configuration['winpe_keyboard_layout'] == '040c:0000040c'
    assert configuration['boot_release'] == 'FR-REPRISE-3'
