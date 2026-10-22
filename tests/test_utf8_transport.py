"""Vérification des caractères français jusqu’au JSON et aux deux PDF."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from app.reports import make_pdf, report_lines

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = "État : déploiement réussi, français suisse, à Noël, cœur, œil, île, où, reçu, € et « l’atelier »."
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


def extract_pdf(path):
    executable = shutil.which('pdftotext')
    if executable:
        return subprocess.check_output([executable, '-layout', str(path), '-'], text=True, encoding='utf-8')
    # La police déclare WinAnsi ; ces octets doivent être présents sans substitution.
    assert SAMPLE.encode('cp1252') in path.read_bytes()
    return SAMPLE


def test_server_pdf_preserves_french_and_historical_inventory_keys(tmp_path):
    report = {'hostname':'PC-LAB-01','status':'completed','generated_at':'2026-10-22',
              'inventory':{'Modele':'Élite','Numero de serie':'TEST1234'},'steps':[], 'warnings':[SAMPLE]}
    lines = list(report_lines(report))
    assert 'Modèle : Élite' in lines and 'Numéro de série : TEST1234' in lines
    assert any('État : Terminé' in line for line in lines)
    assert set(report['inventory']) == {'Modele','Numero de serie'}
    path = tmp_path / 'rapport.pdf'
    path.write_bytes(make_pdf(lines))
    assert SAMPLE in extract_pdf(path)


@pytest.mark.skipif(not PWSH, reason='PowerShell nécessaire')
def test_powershell_utf8_stdin_json_and_pdf(tmp_path):
    report = tmp_path / 'reçu.json'
    pdf = tmp_path / 'rapport.pdf'
    script = tmp_path / 'vérifier.ps1'
    quote = lambda value: "'" + str(value).replace("'", "''").replace("’", "’’") + "'"
    script.write_text("\n".join([
        "$ErrorActionPreference='Stop'",
        '. ' + quote(ROOT / 'scripts/Reporting.ps1'),
        "$code = @'",
        'import json',
        'print(json.dumps({"message": '+repr(SAMPLE)+'}, ensure_ascii=False))',
        "'@",
        '$output = $code | & ' + quote(sys.executable) + ' -',
        "if ($LASTEXITCODE -ne 0) { throw 'Échec du transport Python' }",
        '[IO.File]::WriteAllText('+quote(report)+', $output, [Text.UTF8Encoding]::new($false))',
        'Write-AtelierPdf -Path '+quote(pdf)+' -Lines @('+quote(SAMPLE)+')',
    ]), encoding='utf-8-sig')
    result = subprocess.run([PWSH,'-NoProfile','-File',str(script)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(report.read_text(encoding='utf-8'))['message'] == SAMPLE
    assert SAMPLE in extract_pdf(pdf)


@pytest.mark.skipif(not PWSH or os.name == 'nt', reason='Installateur simulé Linux nécessaire')
def test_client_installer_logs_decode_utf8_without_losing_accents(tmp_path):
    executable = tmp_path / 'winget-fixture'
    executable.write_text('#!/usr/bin/env python3\nimport sys\nprint('+repr(SAMPLE)+')\nprint('+repr(SAMPLE)+',file=sys.stderr)\n',encoding='utf-8')
    executable.chmod(0o755)
    log = tmp_path / 'installation.log'
    script = tmp_path / 'log.ps1'
    script.write_text(". '"+str(ROOT/'scripts/Client-Software.ps1')+"'\n"+
        "Invoke-AtelierClientInstall -Executable '"+str(executable)+"' -Arguments @('install') -LogPath '"+str(log)+"'\n",encoding='utf-8-sig')
    result = subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    text = log.read_text(encoding='utf-8-sig')
    assert text.count(SAMPLE) == 2
    assert '\ufffd' not in text
