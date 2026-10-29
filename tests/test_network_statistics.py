"""Mesures indépendantes du bilan Windows, validation et moyennes réseau pondérées."""
import json
import sqlite3

import pytest

from test_api import auth, prepare, system
from test_reporting import setup_reporter
from test_statistics import calculate, seed


def measurement(**changes):
    return {'source':'winpe_image_rx','status':'measured','application_status':'completed',
            'adapter_name':'Intel Ethernet <fixture>','link_speed_bps':1_000_000_000,
            'received_bytes':1_250_000_000,'duration_seconds':10,'reason':'Octets reçus pendant DISM.',**changes}


def save(data,identifier,payload):
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute('INSERT INTO deployment_network VALUES(?,?,?)',(identifier,json.dumps(payload),'2026-10-20T10:00:00Z'))


def test_receiver_requires_the_deployment_report_token_and_is_idempotent(system):
    client,data,job,reporter=setup_reporter(system)
    route='/api/windows/'+job['id']+'/network'
    for headers in ({},auth(),auth(job['agent_token'])):
        assert client.post(route,headers=headers,json=measurement()).status_code==401
    assert client.post(route,headers=reporter,json=measurement()).status_code==200
    assert client.post(route,headers=reporter,json=measurement()).status_code==200
    assert client.post(route,headers=reporter,json=measurement(received_bytes=20)).status_code==409
    assert client.post(route,headers=reporter,json=measurement(status='unavailable',received_bytes=None,duration_seconds=None)).status_code==409
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        assert con.execute('SELECT COUNT(*) FROM deployment_network').fetchone()[0]==1
        con.execute("UPDATE deployments SET report_expires='2000-01-01' WHERE id=?",(job['id'],))
    assert client.post(route,headers=reporter,json=measurement()).status_code==401


@pytest.mark.parametrize('changes',[
    {'duration_seconds':0},{'duration_seconds':1e-300},{'duration_seconds':-1},{'duration_seconds':'Infinity'},
    {'received_bytes':-1},{'received_bytes':None},{'link_speed_bps':0},
    {'source':'server_bandwidth'},{'adapter_name':'Bad\nname'},
    {'status':'unavailable'},{'started_at':'2026-10-20T10:00:00Z'}])
def test_invalid_samples_never_produce_rates(system,changes):
    client,_,job,reporter=setup_reporter(system)
    assert client.post('/api/windows/'+job['id']+'/network',headers=reporter,json=measurement(**changes)).status_code==422


def test_network_weighting_coverage_and_windows_outcome_are_independent(system):
    client,data=system;_,machine,profile,_=prepare(client,data)
    # Les deux déploiements partagent leur période, pas une liaison serveur additionnée.
    first=seed(data,machine,profile,result='running',report=False)
    save(data,first,measurement())
    second=seed(data,machine,profile,result='needs_attention')
    save(data,second,measurement(duration_seconds=100,link_speed_bps=100_000_000))
    third=seed(data,machine,profile)
    save(data,third,measurement(status='unavailable',duration_seconds=None,received_bytes=None,link_speed_bps=2_500_000_000,reason='Compteur absent'))
    seed(data,machine,profile)
    failed=seed(data,machine,profile,state='failed',result=None,report=False)
    save(data,failed,measurement(application_status='failed',received_bytes=10**15))
    cancelled=seed(data,machine,profile,state='cancelled')
    save(data,cancelled,measurement())
    result=calculate(data)['network']
    assert result['applications']==5 and result['measured']==2
    assert result['missing']==result['unavailable']==result['failed_applications']==1
    assert result['known_links']==3 and result['below_gigabit']==1
    assert result['average_mbps']==181.818
    assert result['best_average_mbps']==1000 and result['lowest_average_mbps']==100
    assert len(result['samples'])==5
    assert client.get('/api/statistics/deployments').status_code==401
    text=json.dumps(client.get('/api/statistics/deployments?days=0',headers=auth()).json())
    assert 'report_token' not in text and 'token_hash' not in text


def test_empty_missing_and_zero_received_are_distinct(system):
    client,data=system;_,machine,profile,_=prepare(client,data)
    assert calculate(data)['network']['average_mbps'] is None
    identifier=seed(data,machine,profile)
    assert calculate(data)['network']['measured']==0
    save(data,identifier,measurement(received_bytes=0,link_speed_bps=None))
    result=calculate(data)['network']
    assert result['measured']==1 and result['average_mbps']==0
    assert result['known_links']==0


def test_network_period_is_filtered_and_list_limit_does_not_truncate_averages(system):
    client,data=system;_,machine,profile,_=prepare(client,data)
    for _ in range(55):
        save(data,seed(data,machine,profile),measurement())
    save(data,seed(data,machine,profile,created='2020-01-01T00:00:00Z'),measurement(duration_seconds=100))
    result=calculate(data)['network']
    assert result['applications']==55 and result['measured']==55
    assert result['listed']==50 and len(result['samples'])==50 and result['average_mbps']==1000
    assert calculate(data,0)['network']['measured']==56
