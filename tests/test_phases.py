"""Étapes confirmées, horodatage stable et compatibilité avec les anciens agents."""
import sqlite3

from test_api import auth, system
from test_reporting import setup_reporter, snapshot


def view(client,identifier):
    response=client.get('/api/deployments/'+identifier+'/pipeline',headers=auth())
    assert response.status_code==200,response.text
    return {step['stage']:step for step in response.json()['job']['pipeline']['stages']}


def test_stage_starts_once_and_completed_stage_is_not_reopened(system):
    client,data,job,reporter=setup_reporter(system)
    route='/api/windows/'+job['id']+'/progress'
    body={'status':'running','progress':10,'message':'Analyse HP','stage':'hpia','stage_status':'running'}
    assert client.post(route,headers=reporter,json=body).status_code==200
    first=view(client,job['id'])['hpia']
    assert first['status']=='running' and first['started_at'] and first['ended_at'] is None
    assert client.post(route,headers=reporter,json={**body,'message':'Installation HP'}).status_code==200
    assert view(client,job['id'])['hpia']['started_at']==first['started_at']
    assert client.post(route,headers=reporter,json={**body,'stage_status':'completed'}).status_code==200
    complete=view(client,job['id'])['hpia']
    assert complete['ended_at'] and complete['status']=='completed'
    assert client.post(route,headers=reporter,json=body).status_code==200
    assert view(client,job['id'])['hpia']==complete
    assert client.get('/api/deployments/'+job['id']+'/pipeline',headers=reporter).status_code==401
    assert client.post(route,headers=auth(),json=body).status_code==401
    assert client.post(route,headers=reporter,json={**body,'stage_started_at':'2000-01-01'}).status_code==422
    assert client.post(route,headers=reporter,json={key:value for key,value in body.items() if key!='stage_status'}).status_code==422


def test_final_report_does_not_invent_the_missing_stages(system):
    client,_,job,reporter=setup_reporter(system)
    assert client.post('/api/agent/'+job['id']+'/events',headers=auth(job['agent_token']),json={'status':'staged','progress':100,'message':'Image appliquée'}).status_code==200
    assert client.post('/api/windows/'+job['id']+'/progress',headers=reporter,json={'status':'running','progress':65,'message':'Dossier IQ','stage':'iq','stage_status':'running'}).status_code==200
    assert client.post('/api/windows/'+job['id']+'/report',headers=reporter,json=snapshot()).status_code==200
    stages=view(client,job['id'])
    assert stages['image']['status']==stages['summary']['status']=='completed'
    assert stages['hpia']['status']==stages['iq']['status']==stages['restart']['status']=='unknown'
    assert stages['iq']['ended_at'] is None
    summary=stages['summary']
    assert client.post('/api/windows/'+job['id']+'/report',headers=reporter,json=snapshot()).status_code==200
    assert view(client,job['id'])['summary']['ended_at']==summary['ended_at']
    state=client.get('/api/state',headers=auth()).json()
    assert state['deployments'][0]['pipeline']['terminal'] is True
    assert state['totals']['active']==0


def test_restart_requires_explicit_confirmation_and_windows_counts_as_active(system):
    client,_,job,reporter=setup_reporter(system)
    assert client.post('/api/agent/'+job['id']+'/events',headers=auth(job['agent_token']),json={'status':'staged','progress':100,'message':'Image appliquée'}).status_code==200
    assert client.get('/api/state',headers=auth()).json()['totals']['active']==1
    route='/api/windows/'+job['id']+'/progress'
    body={'status':'reboot_pending','progress':95,'message':'Redémarrage demandé','stage':'restart','stage_status':'reboot_pending'}
    assert client.post(route,headers=reporter,json=body).status_code==200
    pending=view(client,job['id'])['restart']
    assert pending['status']=='reboot_pending' and pending['ended_at'] is None
    assert client.post(route,headers=reporter,json={**body,'status':'running','stage_status':'completed','message':'Nouveau démarrage confirmé'}).status_code==200
    assert view(client,job['id'])['restart']['status']=='completed'
