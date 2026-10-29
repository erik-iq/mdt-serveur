"""Exécuter les fonctions PowerShell avec des compteurs simulés, sans DISM ni trafic réel."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH,reason='PowerShell nécessaire')


@pytest.mark.parametrize('mode',['normal','reset','route_changed','speed_changed','unavailable','no_counters','speed_unknown','failed','zero'])
def test_counter_delta_rejects_reset_or_route_change_and_preserves_unknowns(tmp_path,mode):
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
param($Project,$Data,$Mode)
$ErrorActionPreference='Stop'
. (Join-Path $Project 'scripts/Network-Measurement.ps1')
$script:reads=0;$script:routes=0
function Get-AtelierImageNetworkAdapter {
 param($ImagePath)
 $script:routes++
 if($Mode -eq 'unavailable'){throw 'Compteur absent'}
 if($Mode -eq 'route_changed' -and $script:routes -gt 1){return 'other'}
 return 'fixture'
}
function Read-AtelierNetworkCounter {
 param($AdapterId)
 $script:reads++
 $speed=if($Mode -eq 'speed_unknown'){$null}elseif($Mode -eq 'speed_changed' -and $script:reads -gt 1){100000000}else{1000000000}
 $received=if($Mode -eq 'no_counters'){$null}elseif($Mode -eq 'reset' -and $script:reads -gt 1){1}elseif($script:reads -gt 1 -and $Mode -ne 'zero'){20000000}else{10000000}
 return @{adapter_name='Carte réseau simulée';link_speed_bps=$speed;received=$received}
}
$context=Start-AtelierImageNetworkMeasurement '\\server\images\fixture.wim'
if($context.clock){
 $context.clock=[pscustomobject]@{Elapsed=[timespan]::FromSeconds(10)}
 $context.clock|Add-Member ScriptMethod Stop {}
}
Stop-AtelierImageNetworkMeasurement $Data $context $(if($Mode -eq 'failed'){'failed'}else{'completed'})
''',encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper),str(ROOT),str(tmp_path),mode],capture_output=True,text=True,timeout=20)
    assert result.returncode==0,result.stdout+result.stderr
    payload=json.loads((tmp_path/'deployment-network.json').read_text('utf-8-sig'))
    if mode in {'normal','speed_unknown','failed','zero'}:
        assert payload['status']=='measured'
        assert payload['duration_seconds']==10
        assert payload['received_bytes']==(0 if mode=='zero' else 10_000_000)
    else:
        assert payload['status']=='unavailable'
        assert payload['duration_seconds'] is None and payload['received_bytes'] is None
    if mode=='speed_unknown':assert payload['link_speed_bps'] is None
    if mode=='no_counters':assert payload['link_speed_bps']==1_000_000_000
    assert payload['application_status']==('failed' if mode=='failed' else 'completed')


def test_reporting_retries_even_without_timings_and_stops_after_receipt(tmp_path):
    payload={'source':'winpe_image_rx','status':'measured','application_status':'completed','adapter_name':'Réseau éthernet',
             'link_speed_bps':1000000000,'received_bytes':10000000,'duration_seconds':10,'reason':'Mesure locale'}
    (tmp_path/'deployment-network.json').write_text(json.dumps(payload,ensure_ascii=False))
    (tmp_path/'reporting.json').write_text(json.dumps({'server_url':'https://atelier.invalid','id':'fixture','token':'fixture-only'}))
    wrapper=tmp_path/'send.ps1'
    wrapper.write_text(r'''
param($Project,$Data)
$ErrorActionPreference='Stop'
. (Join-Path $Project 'scripts/Timings.ps1')
$script:attempt=0
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
 $script:attempt++
 if($script:attempt -eq 1){throw 'Réseau indisponible'}
 if($Uri -ne 'https://atelier.invalid/api/windows/fixture/network'){throw 'Route inattendue'}
 if($ContentType -ne 'application/json; charset=utf-8'){throw 'Encodage incorrect'}
 [IO.File]::WriteAllBytes((Join-Path $Data 'received.json'),$Body)
}
Sync-AtelierTimings $Data
if(Test-Path (Join-Path $Data 'deployment-network.json.sent')){throw 'Reçu créé sans réponse serveur'}
Sync-AtelierTimings $Data
Sync-AtelierTimings $Data
if($script:attempt -ne 2){throw 'Requête répétée après le reçu'}
''',encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper),str(ROOT),str(tmp_path)],capture_output=True,text=True,timeout=20)
    assert result.returncode==0,result.stdout+result.stderr
    assert json.loads((tmp_path/'received.json').read_text())==payload
