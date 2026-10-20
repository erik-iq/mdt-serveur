"""Prepared images stay protected until the operator explicitly starts a new attempt."""
from concurrent.futures import ThreadPoolExecutor
import uuid

import pytest

from test_api import auth
from test_atelier3 import automatic


def discover(client,serial='HP-TEST-1234',previous=None):
    body={'serial_number':serial,'release':'ATELIER-4'}
    if previous is not None:body['reinstall_deployment_id']=previous
    return client.post('/api/boot/discover',json=body)


def prepared(client):
    job=discover(client).json()
    route='/api/agent/'+job['id'];headers=auth(job['agent_token'])
    assert client.post(route+'/claim',headers=headers).status_code==200
    assert client.post(route+'/events',headers=headers,json={'status':'staged','progress':100,'message':'Image prepared'}).status_code==200
    return job


def test_prepared_reinstall_requires_explicit_current_attempt_and_preserves_history(automatic):
    client,_,_,_=automatic
    old=prepared(client)
    events=client.get('/api/deployments/'+old['id']+'/events').json()
    conflict=discover(client)
    assert conflict.status_code==409
    detail=conflict.json()['detail']
    assert detail['code']=='windows_prepared' and detail['deployment_id']==old['id'] and detail['serial_number']=='HP-TEST-1234'
    response=discover(client,previous=old['id'])
    assert response.status_code==200,response.text
    new=response.json()
    assert new['id']!=old['id'] and new['plan']['status']=='queued'
    state=client.get('/api/state').json()
    assert len(state['machines'])==1 and len(state['deployments'])==2
    historical=next(d for d in state['deployments'] if d['id']==old['id'])
    assert historical['status']=='staged' and historical['windows_status'] is None
    assert client.get('/api/deployments/'+old['id']+'/events').json()==events
    assert any(old['id'] in e['message'] for e in client.get('/api/deployments/'+new['id']+'/events').json())
    assert new['plan']['settings']['keyboard']=='100c:0000100c'
    assert new['plan']['settings']['user_locale']=='fr-CH'
    assert new['plan']['settings']['timezone']=='W. Europe Standard Time'


@pytest.mark.parametrize('case',['wrong_job','another_pc','no_serial','old_release','queued','running'])
def test_reinstall_never_takes_an_unrelated_or_active_job(automatic,case):
    client,_,_,_=automatic
    old=prepared(client) if case not in {'queued','running'} else discover(client).json()
    if case=='running':assert client.post('/api/agent/'+old['id']+'/claim',headers=auth(old['agent_token'])).status_code==200
    body={'serial_number':'HP-OTHER-5678' if case=='another_pc' else 'HP-TEST-1234',
          'release':'old' if case=='old_release' else 'ATELIER-4',
          'reinstall_deployment_id':str(uuid.uuid4()) if case=='wrong_job' else old['id']}
    if case=='no_serial':body.pop('serial_number');body['macs']=['00:11:22:33:44:55']
    response=client.post('/api/boot/discover',json=body)
    assert response.status_code==(403 if case=='no_serial' else 409),response.text
    state=client.get('/api/state').json()
    assert len(state['machines'])==len(state['deployments'])==1


def test_concurrent_reinstall_creates_one_attempt_and_normal_reconnect_reuses_it(automatic):
    client,_,_,_=automatic
    old=prepared(client)
    with ThreadPoolExecutor(max_workers=2) as pool:
        replies=list(pool.map(lambda _:discover(client,previous=old['id']),range(2)))
    assert sorted(r.status_code for r in replies)==[200,409]
    new=next(r.json() for r in replies if r.status_code==200)
    assert discover(client).json()['id']==new['id']
    assert len(client.get('/api/state').json()['deployments'])==2
