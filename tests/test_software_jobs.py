"""Web jobs never run a shell in the web server or accept arbitrary package commands."""
from concurrent.futures import ThreadPoolExecutor
import sqlite3
import uuid

from fastapi.testclient import TestClient
from app.main import create_app
from test_api import ADMIN, auth, prepare, register, system


def worker(client, data, identity=None):
    identifier = identity or str(uuid.uuid4())
    headers = auth((data/'software-sync'/'worker-key').read_text())
    assert client.post('/api/software-sync/worker/heartbeat', headers=headers,
                       json={'worker_id':identifier}).status_code == 200
    return identifier, headers


def enqueue(client, bundles=None):
    return client.post('/api/software-sync/jobs', headers=auth(),
                       json={'packages':['vlc','chrome'], 'bundle_ids': bundles or []})


def claim(client, identity, headers):
    return client.post('/api/software-sync/worker/claim', headers=headers, json={'worker_id':identity})


def test_queue_requires_ready_agent_and_whitelisted_selection(system):
    client, data = system
    assert enqueue(client).status_code == 409
    identifier, headers = worker(client, data)
    for packages in ([], ['cmd.exe'], ['vlc','vlc']):
        assert client.post('/api/software-sync/jobs', headers=auth(), json={'packages':packages}).status_code in (400,422)
    assert client.post('/api/software-sync/jobs', headers=auth(), json={'packages':['vlc'],'arguments':'--unsafe'}).status_code == 422
    assert enqueue(client, [str(uuid.uuid4())]).status_code == 404
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute("UPDATE software_worker SET last_seen='2020-01-01T00:00:00+00:00'")
    assert enqueue(client).status_code == 409
    worker(client, data, identifier)
    client.post('/api/software-sync/worker/heartbeat', headers=headers, json={'worker_id':identifier,'state':'not_ready'})
    assert enqueue(client).status_code == 409
    assert client.post('/api/software-sync/jobs',json={'packages':['vlc']}).status_code == 401


def test_only_one_queue_claim_and_deployment_exclusion(system):
    client, data = system
    _,_,_,deployment = prepare(client,data)
    identity, headers = worker(client,data)
    deployed = client.post('/api/deployments', headers=auth(), json=deployment).json()
    assert enqueue(client).status_code == 409
    client.post('/api/deployments/'+deployed['id']+'/cancel',headers=auth())
    with ThreadPoolExecutor(max_workers=2) as pool:
        queued=list(pool.map(lambda _: enqueue(client), range(2)))
    assert sorted(r.status_code for r in queued)==[202,409]
    assert client.post('/api/deployments',headers=auth(),json=deployment).status_code==409
    with ThreadPoolExecutor(max_workers=2) as pool:
        claims=list(pool.map(lambda _: claim(client,identity,headers).json()['job'], range(2)))
    assert len([j for j in claims if j])==1
    job=next(j for j in claims if j)
    assert client.post('/api/software-sync/jobs/'+job['id']+'/finish',headers=headers,
        json={'worker_id':identity,'status':'completed','message':'Terminé'}).status_code==200
    assert client.post('/api/deployments',headers=auth(),json=deployment).status_code==201


def test_worker_key_required_even_in_internal_mode_and_never_disclosed(tmp_path):
    with TestClient(create_app(tmp_path,ADMIN,'https://atelier.test',internal_mode=True)) as client:
        body={'worker_id':str(uuid.uuid4())}
        for headers in ({},auth()):
            assert client.post('/api/software-sync/worker/heartbeat',headers=headers,json=body).status_code==401
        identity, private=worker(client,tmp_path)
        exposed=client.get('/api/state').text+client.get('/api/software-sync').text
        assert private['Authorization'][7:] not in exposed
        assert client.get('/api/software-sync',headers={'Origin':'https://evil.test'}).status_code==403
        assert client.get('/software-sync/worker-key').status_code==404


def test_bundle_append_preserves_other_apps_and_revokes_interrupted_job(system):
    client,data=system
    old=register(client,data,'old.exe','application')
    new=register(client,data,'new.exe','application')
    apps=[client.post('/api/applications',headers=auth(),json={'name':n,'version':'1','asset_id':old['id']}).json()
          for n in ['VLC','HP outil','Chrome']]
    bundle=client.post('/api/bundles',headers=auth(),json={'name':'Standard','application_ids':[apps[1]['id'],apps[0]['id']]}).json()
    identity,headers=worker(client,data)
    queued=enqueue(client,[bundle['id']]);assert queued.status_code==202
    job=claim(client,identity,headers).json()['job']
    route='/api/bundles/'+bundle['id']+'/applications'
    added={'application_ids':[apps[2]['id'],apps[0]['id']]}
    assert client.post(route,headers=auth(),json=added).status_code==409
    mutations={**auth(),'X-Atelier-Software-Job':job['id'],'X-Atelier-Software-Key':headers['Authorization'][7:]}
    replacement={'name':'VLC','version':'2','asset_id':new['id']}
    assert client.put('/api/applications/'+apps[0]['id'],headers=mutations,json=replacement).status_code==200
    for _ in range(2):
        response=client.post(route,headers=mutations,json=added)
        assert response.status_code==200
        assert response.json()['application_ids']==[apps[1]['id'],apps[0]['id'],apps[2]['id']]
    assert client.post(route,headers={**mutations,'X-Atelier-Software-Key':'bad'},json=added).status_code==403
    assert client.post('/api/software-sync/jobs/'+job['id']+'/progress',headers=headers,
        json={'worker_id':identity,'progress':65,'message':'Vérification de VLC'}).status_code==200
    # Simulate a process restart after it acquired the single worker OS mutex.
    worker(client,data)
    state=client.get('/api/software-sync',headers=auth()).json()
    assert state['job']['status']=='interrupted'
    assert client.post(route,headers=mutations,json=added).status_code==409
    assert client.put('/api/applications/'+apps[0]['id'],headers=mutations,json=replacement).status_code==409
    assert client.post('/api/software-sync/jobs/'+job['id']+'/finish',headers=headers,
        json={'worker_id':identity,'status':'completed'}).status_code==409
    assert client.get('/api/state',headers=auth()).json()['applications'][0]['id']


def test_partial_result_keeps_diagnostic_and_bundle_validation(system):
    client,data=system
    app=client.post('/api/applications',headers=auth(),json={'name':'VLC','asset_id':register(client,data,'vlc.exe','application')['id']}).json()
    bundle=client.post('/api/bundles',headers=auth(),json={'name':'Standard','application_ids':[app['id']]}).json()
    route='/api/bundles/'+bundle['id']+'/applications'
    assert client.post(route,headers=auth(),json={'application_ids':[str(uuid.uuid4())]}).status_code==404
    assert client.post(route,headers=auth(),json={'application_ids':[]}).status_code==422
    identity,headers=worker(client,data)
    job=enqueue(client).json();claim(client,identity,headers)
    results={'applications':[{'package':'vlc','status':'unchanged','application_id':app['id']},
                             {'package':'chrome','status':'failed','message':'Signature refusée'}]}
    response=client.post('/api/software-sync/jobs/'+job['id']+'/finish',headers=headers,
                        json={'worker_id':identity,'status':'partial','results':results,'message':'Résultat partiel'})
    assert response.status_code==200
    assert client.get('/api/software-sync',headers=auth()).json()['job']['results']==results


def test_queued_request_can_be_cancelled_but_running_request_cannot(system):
    client,data=system
    identity,headers=worker(client,data)
    job=enqueue(client).json()
    route='/api/software-sync/jobs/'+job['id']+'/cancel'
    assert client.post(route).status_code==401
    assert client.post(route,headers=auth()).status_code==200
    assert claim(client,identity,headers).json()['job'] is None
    assert client.get('/api/software-sync',headers=auth()).json()['job']['status']=='interrupted'
    job=enqueue(client).json();claim(client,identity,headers)
    assert client.post('/api/software-sync/jobs/'+job['id']+'/cancel',headers=auth()).status_code==409
