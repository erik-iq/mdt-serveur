"""Exécute durable answer-file writes and repair on a synthetic offline tree."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell is required for answer-file execution tests')
NS = {'u': 'urn:schemas-microsoft-com:unattend'}


def quote(path):
    return "'" + str(path).replace("'", "''") + "'"


def execute(tmp_path, body):
    script = tmp_path / 'verify.ps1'
    script.write_text("$ErrorActionPreference='Stop'\n. " + quote(ROOT / 'scripts' / 'Unattend.ps1') + '\n' + body,
                      encoding='utf-8-sig')
    result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                             '-File', str(script)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout.lstrip('\ufeff').strip())


def settings():
    return {'keyboard': '100c:0000100c', 'timezone': 'W. Europe Standard Time', 'user_locale': 'fr-CH',
            'registered_owner': 'Équipe & IT', 'organization': 'Atelier <Paris>'}


def fixture(tmp_path):
    windows = tmp_path / 'disk' / 'Windows'
    panther = windows / 'Panther'
    panther.mkdir(parents=True)
    answer = panther / 'unattend.xml'
    answer.write_bytes(bytes(1351))
    payload = tmp_path / 'disk' / 'ProgramData' / 'AtelierPXE'
    payload.mkdir(parents=True)
    personalization = {'settings': settings(), 'applications': [{'id': 'vlc'}], 'wallpaper': {'filename': 'Fond-Atelier.png'}}
    (payload / 'personalization.json').write_text(json.dumps(personalization), encoding='utf-8')
    for name in ('FirstLogon.ps1', 'Unattend.ps1'):
        (payload / name).write_text("Write-Output 'Fixture script'", encoding='utf-8-sig')
    backup = tmp_path / 'private-backup'
    backup.mkdir()
    return windows, answer, payload, backup


def repair(tmp_path, windows, backup):
    return execute(tmp_path, f"""
try {{
    $report=Repair-AtelierOfflineUnattend -WindowsPath {quote(windows)} -ComputerName 'PC-TEST-PXE' -Locale 'fr-FR' -BackupDirectory {quote(backup)}
    @{{success=$true;report=$report}} | ConvertTo-Json -Depth 5 -Compress
}} catch {{ @{{success=$false;reason=$_.Exception.Message}} | ConvertTo-Json -Compress }}
""")


def test_durable_utf8_write_preserves_unicode_and_can_be_verified(tmp_path):
    path = tmp_path / 'Panther' / 'unattend.xml'
    plan = tmp_path / 'plan.json'
    plan.write_text(json.dumps({'hostname': 'PC-TEST-PXE', 'locale': 'fr-FR', 'settings': settings()}), encoding='utf-8')
    result = execute(tmp_path, f"""
$plan=Get-Content -LiteralPath {quote(plan)} -Raw | ConvertFrom-Json
$xml=New-AtelierUnattend -Plan $plan
$record=Write-AtelierVerifiedUtf8File -Path {quote(path)} -Content $xml -Unattend
Assert-AtelierUnattendFile -Path {quote(path)} -ExpectedHash $record.sha256
$record | ConvertTo-Json -Compress
""")
    data = path.read_bytes()
    assert not data.startswith(b'\xef\xbb\xbf')
    assert b'\x00' not in data
    assert result['size_bytes'] == len(data)
    assert result['sha256'] == hashlib.sha256(data).hexdigest()
    document = ET.fromstring(data)
    assert document.find('.//u:RegisteredOwner', NS).text == settings()['registered_owner']
    assert document.find('.//u:InputLocale', NS).text == settings()['keyboard']
    assert not list(path.parent.glob('.atelier-*.tmp'))


@pytest.mark.parametrize('content', ['', '   ', '\x00' * 1351, '<unattend>', '<unattend/>'])
def test_invalid_content_never_replaces_existing_file(tmp_path, content):
    target = tmp_path / 'unattend.xml'
    target.write_bytes(b'preserve existing file')
    input_path = tmp_path / 'input.txt'
    input_path.write_bytes(content.encode('utf-8'))
    result = execute(tmp_path, f"""
try {{
    Write-AtelierVerifiedUtf8File -Path {quote(target)} -Content ([IO.File]::ReadAllText({quote(input_path)})) -Unattend | Out-Null
    @{{rejected=$false}} | ConvertTo-Json
}} catch {{ @{{rejected=$true}} | ConvertTo-Json }}
""")
    assert result['rejected'] is True
    assert target.read_bytes() == b'preserve existing file'
    assert not list(tmp_path.glob('.atelier-*.tmp'))


def test_readback_rejects_zeroed_file_even_when_length_is_unchanged(tmp_path):
    target = tmp_path / 'unattend.xml'
    result = execute(tmp_path, f"""
$xml=New-AtelierUnattend -Plan ([pscustomobject]@{{hostname='PC-TEST-PXE';locale='fr-FR'}})
$record=Write-AtelierVerifiedUtf8File -Path {quote(target)} -Content $xml -Unattend
[IO.File]::WriteAllBytes({quote(target)},(New-Object byte[] $record.size_bytes))
try {{ Assert-AtelierUnattendFile -Path {quote(target)} -ExpectedHash $record.sha256; @{{rejected=$false}} | ConvertTo-Json }}
catch {{ @{{rejected=$true}} | ConvertTo-Json }}
""")
    assert result['rejected'] is True


def test_repair_exact_reported_corruption_preserves_bundle_and_wallpaper(tmp_path):
    windows, answer, payload, backup = fixture(tmp_path)
    before = {p.name: p.read_bytes() for p in payload.iterdir()}
    result = repair(tmp_path, windows, backup)
    assert result['success'] is True, result
    assert (backup / 'unattend.original.bin').read_bytes() == bytes(1351)
    assert result['report']['original_size'] == 1351
    assert result['report']['sha256'] == hashlib.sha256(answer.read_bytes()).hexdigest()
    assert json.loads((backup / 'repair.json').read_text())['windows_setup_validation'] == 'not_performed'
    document = ET.fromstring(answer.read_bytes())
    assert document.find('.//u:ComputerName', NS).text == 'PC-TEST-PXE'
    assert document.find('.//u:UILanguage', NS).text == 'fr-FR'
    assert document.find('.//u:InputLocale', NS).text == settings()['keyboard']
    assert document.find('.//u:TimeZone', NS).text == settings()['timezone']
    assert document.find('.//u:CommandLine', NS).text.endswith('FirstLogon.ps1"')
    assert {p.name: p.read_bytes() for p in payload.iterdir()} == before
    assert list(answer.parent.glob('unattend.xml.previous-*'))[0].read_bytes() == bytes(1351)
    repeated = repair(tmp_path, windows, backup)
    assert repeated['success'] is False
    assert 'non nulles' in repeated['reason']


@pytest.mark.parametrize('broken', ['missing-payload', 'zeroed-payload', 'missing-script', 'zeroed-script', 'invalid-script'])
def test_repair_refuses_incomplete_personalization_without_touching_xml(tmp_path, broken):
    windows, answer, payload, backup = fixture(tmp_path)
    if broken == 'missing-payload':
        (payload / 'personalization.json').unlink()
    elif broken == 'zeroed-payload':
        (payload / 'personalization.json').write_bytes(bytes(100))
    elif broken == 'missing-script':
        (payload / 'FirstLogon.ps1').unlink()
    elif broken == 'zeroed-script':
        (payload / 'FirstLogon.ps1').write_bytes(bytes(100))
    else:
        (payload / 'FirstLogon.ps1').write_text('function {', encoding='utf-8')
    result = repair(tmp_path, windows, backup)
    assert result['success'] is False
    assert answer.read_bytes() == bytes(1351)
    assert not list(backup.iterdir())


def test_writer_refuses_symlink_parent(tmp_path):
    actual = tmp_path / 'actual'
    actual.mkdir()
    link = tmp_path / 'link'
    try:
        link.symlink_to(actual, target_is_directory=True)
    except OSError:
        pytest.skip('Creating symlinks requires permission')
    result = execute(tmp_path, f"""
try {{ Write-AtelierVerifiedUtf8File -Path {quote(link / 'file.json')} -Content '{{"value":1}}' | Out-Null; @{{rejected=$false}} | ConvertTo-Json }}
catch {{ @{{rejected=$true}} | ConvertTo-Json }}
""")
    assert result['rejected'] is True
    assert not list(actual.iterdir())


def test_offline_repair_keeps_background_launcher_when_payload_has_it(tmp_path):
    windows, answer, payload, backup = fixture(tmp_path)
    (payload/'Start-Preparation.ps1').write_text("Write-Output 'Fixture launcher'")
    result=repair(tmp_path, windows, backup)
    assert result['success'] is True, result
    document=ET.fromstring(answer.read_bytes())
    assert document.find('.//u:CommandLine', NS).text.endswith('Start-Preparation.ps1"')
