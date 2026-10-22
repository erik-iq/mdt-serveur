"""PowerShell 5.1 must read sources without an ambiguous legacy code page."""
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


def test_executable_sources_are_ascii_but_runtime_data_can_stay_utf8():
    files=list((ROOT/'scripts').glob('*.ps1'))+list((ROOT/'scripts').glob('*.cmd'))
    files+=list((ROOT/'scripts').glob('*.py'))+list((ROOT/'app').glob('*.py'))
    files.append(ROOT/'app'/'static'/'app.js')
    files.append(ROOT/'app'/'static'/'maintenance.js')
    for path in files:
        path.read_bytes().decode('ascii')
