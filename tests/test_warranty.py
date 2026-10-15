"""Calendar boundaries: a month is not approximated by thirty days."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell required')


@pytest.mark.parametrize(('start','end','months'),[
    ('2026-01-31','2026-02-28',1),('2026-01-15','2026-02-14',0),
    ('2024-02-29','2025-02-28',12),('2026-10-15','2026-10-14',0),
    ('2026-10-15','2029-10-15',36)])
def test_complete_calendar_months(tmp_path,start,end,months):
    script=tmp_path/'date.ps1'
    script.write_text(". '"+str(ROOT/'scripts'/'Verifier-Garantie.ps1')+"'\nGet-AtelierWarrantyMonths ([datetime]'"+start+"') ([datetime]'"+end+"')",encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=15)
    assert result.returncode==0,result.stderr
    assert int(result.stdout.strip())==months
