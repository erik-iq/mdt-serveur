"""Execute the real activation guard using SQLite/Python and legacy native quoting."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell required')


@pytest.mark.parametrize(('case', 'expected'), [('idle',0), ('running',2), ('missing',None), ('bad_schema',None)])
def test_activation_database_guard_with_legacy_arguments(tmp_path, case, expected):
    folder = tmp_path / 'database with spaces'
    folder.mkdir()
    database = folder / 'deployment.sqlite3'
    if case != 'missing':
        with sqlite3.connect(database) as con:
            if case != 'bad_schema':
                con.execute('CREATE TABLE deployments(status TEXT)')
                con.executemany('INSERT INTO deployments VALUES (?)', [('queued',),('staged',),('failed',)] + [('running',)] * (2 if case=='running' else 0))
    wrapper = tmp_path / 'verify.ps1'
    quote = lambda value: str(value).replace("'", "''")
    wrapper.write_text(r"""
$ErrorActionPreference='Stop'
$PSNativeCommandArgumentPassing='Legacy'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('SOURCE',[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Parser failure' }
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AtelierActiveDeploymentCount'},$true)
if (-not $definition) { throw 'Guard function missing' }
Set-Item -Path Function:\Get-AtelierActiveDeploymentCount -Value $definition.Body.GetScriptBlock()
try {
    $count=Get-AtelierActiveDeploymentCount -Runtime 'PYTHON' -Database 'DATABASE'
    @{count=$count;failed=$false} | ConvertTo-Json -Compress
} catch { @{count=$null;failed=$true;message=$_.Exception.Message} | ConvertTo-Json -Compress }
""".replace('SOURCE',quote(ROOT/'scripts'/'Enable-InternalMode.ps1'))
        .replace('PYTHON',quote(sys.executable)).replace('DATABASE',quote(database)), encoding='utf-8-sig')
    result = subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout.strip())
    assert report['count'] == expected, report
    assert report['failed'] == (expected is None), report
    if expected is None:
        assert 'Terminez les deploiements' not in report['message']
    if case == 'missing':
        assert not database.exists()  # Read-only URI must not create an empty database.
