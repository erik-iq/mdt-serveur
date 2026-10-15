"""Collect setup files from an artificial Windows tree without mounting a disk."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
ELEVATED = os.name != 'nt' or bool(ctypes.windll.shell32.IsUserAnAdmin())
pytestmark = pytest.mark.skipif(not PWSH or not ELEVATED, reason='PowerShell is required; Windows also requires an elevated session')
SCRIPT = ROOT / 'scripts' / 'Get-VMSetupDiagnostics.ps1'


def collect(windows, output):
    return subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                           '-File', str(SCRIPT), '-WindowsPath', str(windows), '-OutputPath', str(output)],
                          capture_output=True, text=True, timeout=30)


def digest_tree(root):
    return {str(file.relative_to(root)): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in root.rglob('*') if file.is_file()}


@pytest.mark.parametrize(('content', 'valid', 'reason', 'encoding'), [
    (b'', False, 'empty', 'unknown'),
    (b'\x00' * 1351, False, 'invalid_xml', 'unknown'),
    (b'   \r\n ', False, 'invalid_xml', 'unknown'),
    (b'<unattend>', False, 'invalid_xml', 'unknown'),
    (b'<?xml version="1.0" encoding="utf-8"?><unattend xmlns="urn:schemas-microsoft-com:unattend"/>', True, 'well_formed_xml', 'unknown'),
    ('<?xml version="1.0" encoding="utf-8"?><unattend/>'.encode('utf-8-sig'), True, 'well_formed_xml', 'UTF-8 BOM'),
    ('<?xml version="1.0" encoding="utf-16"?><unattend/>'.encode('utf-16'), True, 'well_formed_xml', 'UTF-16 LE BOM'),
    ('<?xml version="1.0" encoding="utf-8"?><unattend/>'.encode('utf-16'), False, 'invalid_xml', 'UTF-16 LE BOM'),
])
def test_answer_file_metadata_xml_and_exact_file_copy(tmp_path, content, valid, reason, encoding):
    windows = tmp_path / 'Windows'
    panther = windows / 'Panther'
    panther.mkdir(parents=True)
    (panther / 'unattend.xml').write_bytes(content)
    (panther / 'setuperr.log').write_text('Unable to deserialize; status=0x800705b9', encoding='utf-8')
    gc = panther / 'UnattendGC'
    gc.mkdir()
    (gc / 'setupact.log').write_text('Detailed fixture log', encoding='utf-8')
    source_before = digest_tree(windows)
    output = tmp_path / 'report'
    result = collect(windows, output)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((output / 'diagnostic.json').read_text(encoding='utf-8-sig'))
    answer = next(item for item in report['answer_files'] if item['file'] == 'Panther-unattend.xml')
    assert answer['exists'] is True
    assert answer['size_bytes'] == len(content)
    assert answer['xml_valid'] is valid
    assert answer['reason'] == reason
    assert answer['encoding'] == encoding
    assert answer['zero_bytes'] == content.count(b'\x00')
    assert answer['all_bytes_zero'] == (bool(content) and not content.strip(b'\x00'))
    assert (output / 'Panther-unattend.xml').read_bytes() == content
    assert (output / 'Panther-setuperr.log').read_bytes() == (panther / 'setuperr.log').read_bytes()
    assert (output / 'Panther-UnattendGC-setupact.log').is_file()
    assert digest_tree(windows) == source_before


def test_absent_answer_file_is_distinguished_from_empty(tmp_path):
    windows = tmp_path / 'Windows'
    windows.mkdir()
    output = tmp_path / 'report'
    result = collect(windows, output)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((output / 'diagnostic.json').read_text(encoding='utf-8-sig'))
    assert len(report['answer_files']) == 2
    assert all(not answer['exists'] and answer['reason'] == 'missing' for answer in report['answer_files'])
    assert not (output / 'Panther-unattend.xml').exists()


def test_output_must_not_modify_the_windows_source(tmp_path):
    windows = tmp_path / 'Windows'
    windows.mkdir()
    result = collect(windows, windows / 'new-report')
    assert result.returncode != 0
    assert not (windows / 'new-report').exists()


def test_existing_output_is_preserved(tmp_path):
    windows = tmp_path / 'Windows'
    windows.mkdir()
    output = tmp_path / 'report'
    output.mkdir()
    marker = output / 'marker'
    marker.write_text('preserve', encoding='utf-8')
    result = collect(windows, output)
    assert result.returncode != 0
    assert marker.read_text() == 'preserve'
    assert list(output.iterdir()) == [marker]


def test_symlink_does_not_copy_files_outside_the_windows_tree(tmp_path):
    windows = tmp_path / 'Windows'
    windows.mkdir()
    external = tmp_path / 'private'
    external.mkdir()
    (external / 'unattend.xml').write_text('private data', encoding='utf-8')
    (windows / 'Panther').symlink_to(external, target_is_directory=True)
    output = tmp_path / 'report'
    result = collect(windows, output)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (output / 'Panther-unattend.xml').exists()
    assert 'private data' not in (output / 'diagnostic.json').read_text()
