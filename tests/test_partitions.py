"""Execute the partition guard with simulated storage; never modify a real disk."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('ATELIER_PWSH') or shutil.which('pwsh') or shutil.which('powershell')
pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell is required for partition guard tests')


def run_ps(tmp_path, body, fixture):
    helper = str(ROOT / 'scripts' / 'Partitions.ps1').replace("'", "''")
    fixture_path = tmp_path / 'fixture.json'
    fixture_path.write_text(json.dumps(fixture), encoding='utf-8')
    fixture_literal = str(fixture_path).replace("'", "''")
    script = tmp_path / 'verify.ps1'
    script.write_text("$ErrorActionPreference='Stop'\n. '" + helper + "'\n" +
                      "$fixture=Get-Content -LiteralPath '" + fixture_literal + "' -Raw | ConvertFrom-Json\n" + body,
                      encoding='utf-8-sig')
    result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                             'Bypass', '-File', str(script)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout.lstrip('\ufeff').strip())


def layout():
    # Hidden EFI and Recovery deliberately have NO DriveLetter, and AccessPaths
    # only contains their volume GUID. The DOS letters are resolved separately.
    definitions = [
        (1, 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b', 'S', 260 * 1024**2, 'FAT32'),
        (2, 'e3c9e316-0b5c-4db8-817d-f92df00215ae', '', 16 * 1024**2, ''),
        (3, 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7', 'W', 98 * 1024**3, 'NTFS'),
        (4, 'de94bba4-06d1-4d40-a16a-bfd50179d6ac', 'R', 1024**3, 'NTFS'),
    ]
    partitions, volumes = [], {}
    for number, gpt_type, letter, size, filesystem in definitions:
        path = '\\\\?\\Volume{' + f'{number:08d}-1234-5678-90ab-0123456789ab' + '}\\'
        partitions.append({'PartitionNumber': number, 'DiskNumber': 7, 'GptType': '{'+gpt_type+'}',
                           'Size': size, 'DriveLetter': letter if letter == 'W' else '', 'AccessPaths': [path] if letter else []})
        if letter:
            volumes[letter] = {'Path': path, 'FileSystem': filesystem}
    return {'disk': {'Number': 7, 'UniqueId': 'target-disk-id', 'Size': 100 * 1024**3, 'PartitionStyle': 'GPT'},
            'partition_sets': [partitions], 'volumes': volumes}


GUARD = """
$script:queries=0
$script:refreshes=0
function Update-HostStorageCache { [CmdletBinding()] param() $script:refreshes++ }
function Get-Disk { [CmdletBinding()] param($Number) return $fixture.disk }
function Get-Partition {
    [CmdletBinding()] param($DiskNumber,$DriveLetter)
    if ($PSBoundParameters.ContainsKey('DriveLetter')) { throw 'Forbidden drive-letter lookup' }
    $index=[math]::Min($script:queries,$fixture.partition_sets.Count-1)
    $script:queries++
    return $fixture.partition_sets[$index]
}
function Get-AtelierVolumeIdentity {
    param($DriveLetter)
    $volume=$fixture.volumes.PSObject.Properties[$DriveLetter]
    if (-not $volume) { throw "Volume ${DriveLetter}: absent" }
    return $volume.Value
}
try {
    Wait-AtelierTargetPartitions -DiskNumber 7 -ExpectedUniqueId 'target-disk-id' -ExpectedSize 107374182400 -Attempts 3 -RetryDelayMilliseconds 0
    $answer=@{success=$true;reason=''}
} catch { $answer=@{success=$false;reason=$_.Exception.Message} }
$answer.queries=$script:queries
$answer.refreshes=$script:refreshes
$answer | ConvertTo-Json -Compress
"""


def test_hidden_efi_without_drive_letter_is_verified_by_volume_guid(tmp_path):
    answer = run_ps(tmp_path, GUARD, layout())
    assert answer == {'success': True, 'reason': '', 'queries': 1, 'refreshes': 1}


def test_stale_partition_inventory_is_refreshed_and_retried(tmp_path):
    fixture = layout()
    fixture['partition_sets'].insert(0, [])
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is True
    assert answer['queries'] == answer['refreshes'] == 2


def test_missing_partition_is_rejected_after_bounded_retries(tmp_path):
    fixture = layout()
    fixture['partition_sets'][0].pop()
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is False
    assert answer['queries'] == 3
    assert 'Quatre partitions attendues' in answer['reason']


@pytest.mark.parametrize('letter', ['S', 'W', 'R'])
def test_letter_resolving_to_a_different_volume_is_rejected(tmp_path, letter):
    fixture = layout()
    fixture['volumes'][letter]['Path'] = '\\\\?\\Volume{ffffffff-ffff-ffff-ffff-ffffffffffff}\\'
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is False
    assert f'Le volume {letter}:' in answer['reason']


@pytest.mark.parametrize('partition_index', [0, 1, 2, 3])
def test_incorrect_gpt_role_is_rejected(tmp_path, partition_index):
    fixture = layout()
    fixture['partition_sets'][0][partition_index]['GptType'] = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is False
    assert 'type GPT ou taille incorrects' in answer['reason']


@pytest.mark.parametrize(('field', 'value'), [('Number', 8), ('UniqueId', 'another-disk'), ('Size', 108000000000)])
def test_disk_identity_change_is_immediately_rejected(tmp_path, field, value):
    fixture = layout()
    fixture['disk'][field] = value
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is False
    assert 'identite du disque cible a change' in answer['reason']
    assert answer['queries'] == 0 and answer['refreshes'] == 1


@pytest.mark.parametrize('letter', ['S', 'W', 'R'])
def test_incorrect_filesystem_is_rejected(tmp_path, letter):
    fixture = layout()
    fixture['volumes'][letter]['FileSystem'] = 'exFAT'
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is False
    assert f'Volume {letter}: attendu en' in answer['reason']


def test_missing_efi_mount_is_not_accepted(tmp_path):
    fixture = layout()
    del fixture['volumes']['S']
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is False
    assert 'Volume S: absent' in answer['reason']


def test_foreign_partition_is_not_accepted(tmp_path):
    fixture = layout()
    fixture['partition_sets'][0][0]['DiskNumber'] = 8
    answer = run_ps(tmp_path, GUARD, fixture)
    assert answer['success'] is False
    assert 'disque, type GPT ou taille incorrects' in answer['reason']


@pytest.mark.parametrize(('exit_code', 'output', 'success'), [
    (0, ['    \\\\?\\Volume{12345678-abcd-abcd-abcd-123456789abc}\\'], True),
    (0, ['Aucun volume'], False),
    (0, ['\\\\?\\Volume{12345678-abcd-abcd-abcd-123456789abc}\\', '\\\\?\\Volume{87654321-abcd-abcd-abcd-123456789abc}\\'], False),
    (1, ['\\\\?\\Volume{12345678-abcd-abcd-abcd-123456789abc}\\'], False),
])
def test_mountvol_output_requires_one_valid_guid_and_success_exit(tmp_path, exit_code, output, success):
    answer = run_ps(tmp_path, """
function mountvol.exe {
    $global:LASTEXITCODE=$fixture.exit_code
    return $fixture.output
}
try {
    $path=Get-AtelierVolumeGuid -DriveLetter S
    @{success=$true;path=$path} | ConvertTo-Json -Compress
} catch { @{success=$false;path=''} | ConvertTo-Json -Compress }
""", {'exit_code': exit_code, 'output': output})
    assert answer['success'] == success
    if success:
        assert answer['path'] == output[0].strip()
