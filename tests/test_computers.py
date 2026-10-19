"""Scoped history, operator observations, and idempotent measured durations."""
import sqlite3
import uuid

from test_api import auth, system
from test_reporting import setup_reporter, snapshot


def timing(run=None,**overrides):
    return dict(run_id=run or str(uuid.uuid4()),source='windows',stage='software',status='completed',started_at='2026-10-19T09:00:00Z',duration_seconds=12.5,**overrides)


def test_notes_snapshot_history_and_access_control(system):
    client,data,job,reporter=setup_reporter(system)
    machine=client.get('/api/state',headers=auth()).json()['machines'][0]
    url='/api/machines/'+machine['id']
    assert client.get(url+'/details').status_code==401
    assert client.post(url+'/notes',headers=reporter,json={'text':'private'}).status_code==401
    response=client.post(url+'/notes',headers=auth(),json={'author':'Technicien','text':'Ecran verifie\n<script>test</script>'})
    assert response.status_code==201
    assert client.post(url+'/notes',headers=auth(),json={'text':'  '}).status_code==422
    assert client.post('/api/machines/missing/notes',headers=auth(),json={'text':'test'}).status_code==404
    assert client.post('/api/windows/'+job['id']+'/report',headers=reporter,json=snapshot()).status_code==200
    detail=client.get(url+'/details',headers=auth()).json()
    assert detail['total']==1 and detail['deployments'][0]['id']==job['id']
    assert detail['latest_report']['inventory']['Windows']=='Windows 11 Pro'
    assert detail['notes'][0]['text']=='Ecran verifie\n<script>test</script>'
    assert client.get('/api/deployments/'+job['id']+'/report',headers=auth()).json()['hostname']==machine['hostname']
    assert client.get('/api/deployments/'+job['id']+'/report',headers=reporter).status_code==401
    other=client.post('/api/machines',headers=auth(),json={'hostname':'OTHER-PC','mac':'00:11:22:33:44:66'}).json()
    other_detail=client.get('/api/machines/'+other['id']+'/details',headers=auth()).json()
    assert other_detail['notes']==[] and other_detail['latest_report'] is None and other_detail['total']==0
    assert client.get(url+'/details?offset=1&limit=1',headers=auth()).json()['deployments']==[]


def test_timings_use_reporter_credentials_and_do_not_regress_or_duplicate(system):
    client,data,job,reporter=setup_reporter(system)
    url='/api/windows/'+job['id']+'/timings'
    entry=timing()
    assert client.post(url,headers=auth(),json={'measurements':[entry]}).status_code==401
    assert client.post(url,headers=reporter,json={'measurements':[entry]}).status_code==200
    assert client.post(url,headers=reporter,json={'measurements':[entry]}).status_code==200
    stale={**entry,'status':'running','duration_seconds':0}
    assert client.post(url,headers=reporter,json={'measurements':[stale]}).status_code==200
    rows=client.get('/api/deployments/'+job['id']+'/timings',headers=auth()).json()['measurements']
    assert len(rows)==1 and rows[0]['duration_seconds']==12.5 and rows[0]['status']=='completed'
    hp={**entry,'run_id':str(uuid.uuid4()),'stage':'hp_updates'}
    assert client.post(url,headers=reporter,json={'measurements':[hp]}).status_code==200
    assert any(row['label']=='Mises a jour HP' for row in client.get('/api/deployments/'+job['id']+'/timings',headers=auth()).json()['measurements'])
    assert client.post(url,headers=reporter,json={'measurements':[{**entry,'stage':'image'}]}).status_code==409
    assert client.post(url,headers=reporter,json={'measurements':[{**entry,'duration_seconds':-1}]}).status_code==422
    assert client.post(url,headers=reporter,json={'measurements':[{**entry,'started_at':'2026-10-19T09:00:00'}]}).status_code==422
    with sqlite3.connect(data/'deployment.sqlite3') as con:con.execute("UPDATE deployments SET report_expires='2000-01-01' WHERE id=?",(job['id'],))
    assert client.post(url,headers=reporter,json={'measurements':[entry]}).status_code==401


def test_json_charset_is_explicit_for_windows_powershell(system):
    client,_=system
    response=client.get('/api/session')
    assert response.headers['content-type']=='application/json; charset=utf-8'
