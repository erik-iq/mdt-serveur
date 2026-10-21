"""Keep HP's native installation page separate from the pre-install analysis."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

from test_hpia_generic_reference import ROOT, PWSH

pytestmark = pytest.mark.skipif(not PWSH, reason='PowerShell required')


@pytest.mark.parametrize('case', ['native', 'two_passes', 'analysis_only', 'standalone'])
def test_native_installation_html_is_preserved_and_latest_alias_is_deployment_only(tmp_path, case):
    iq = tmp_path / 'IQ_'
    reports = iq / 'Rapports/HPImageAssistant/job'
    first = reports / 'Passage-01/Installation'
    first.mkdir(parents=True)
    (first / 'HP Model.html').write_text('Analysis report must not become the installation page')
    if case != 'analysis_only':
        page = first / 'Readme (20261021 152514).html'
        page.write_text('<html><meta charset="utf-16"><body>Installation HP: succ\u00e8s</body></html>', encoding='utf-16')
        os.utime(page, (100, 100))
        if case == 'two_passes':
            page = reports / 'Passage-02/Installation/Readme (20261021 153000).html'
            page.parent.mkdir(parents=True)
            page.write_text('<html>Installation HP passage 2</html>')
            os.utime(page, (200, 200))
        expected = page.read_bytes()
    script = tmp_path / 'test.ps1'
    script.write_text(r'''
$ErrorActionPreference='Stop'
. 'PROJECT/scripts/HP-ImageAssistant.ps1'
$page=Export-AtelierHpiaInstallationReport -Directory 'REPORTS' -ToolsPath 'IQ' -PublishLatest:('CASE' -ne 'standalone')
@{page=$page} | ConvertTo-Json -Compress
'''.replace('PROJECT', str(ROOT)).replace('REPORTS', str(reports)).replace("'IQ'", "'"+str(iq)+"'").replace('CASE', case))
    run = subprocess.run([PWSH, '-NoProfile', '-File', str(script)], capture_output=True, text=True, timeout=25)
    assert run.returncode == 0, run.stdout + run.stderr
    result = json.loads(run.stdout)
    if case == 'analysis_only':
        assert result['page'] is None
        assert not (iq / 'Rapports/Rapport-Installation-HP.html').exists()
    else:
        assert Path(result['page']).read_bytes() == expected
        alias = iq / 'Rapports/Rapport-Installation-HP.html'
        assert alias.exists() == (case != 'standalone')
        if alias.exists():
            assert alias.read_bytes() == expected
