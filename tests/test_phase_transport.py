"""Le transport existant porte les étapes sans ajouter de requête ni de fichier partagé."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


@pytest.mark.skipif(not PWSH,reason='PowerShell nécessaire')
def test_real_reporting_includes_only_explicit_phase(tmp_path):
    (tmp_path/'reporting.json').write_text(json.dumps({'server_url':'https://atelier.invalid','id':'fixture','token':'fixture-only'}))
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text('''
param($Project,$Data)
. (Join-Path $Project 'scripts/Reporting.ps1')
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 $value=[Text.Encoding]::UTF8.GetString($Body)
 Add-Content (Join-Path $Data 'sent.jsonl') $value -Encoding utf8
}
Send-AtelierWindowsProgress $Data 'running' 5 'Préparation démarrée'
$script:AtelierDeploymentStage='hpia';$script:AtelierDeploymentStageStatus='running'
Send-AtelierWindowsProgress $Data 'running' 10 'Analyse HP démarrée'
$script:AtelierDeploymentStageStatus='completed'
Send-AtelierWindowsProgress $Data 'running' 10 'Pilotes installés'
$script:AtelierDeploymentStage=''
Send-AtelierWindowsProgress $Data 'completed' 100 'Bilan préparé'
''',encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper),str(ROOT),str(tmp_path)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stdout+result.stderr
    values=[json.loads(line) for line in (tmp_path/'sent.jsonl').read_text('utf-8-sig').splitlines()]
    assert len(values)==4
    assert 'stage' not in values[0] and 'stage_status' not in values[3]
    assert values[1]['stage']=='hpia' and values[1]['stage_status']=='running'
    assert values[2]['stage_status']=='completed' and values[2]['message']=='Pilotes installés'
