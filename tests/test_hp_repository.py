"""Real queue/snapshot HTTP protocol with synthetic packages, never HP installers."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
import hashlib
import json
from pathlib import Path
import sqlite3
import uuid
import zipfile

import pytest

from test_api import auth, system
from test_reporting import setup_reporter
from app.hp_repository import HpRepository
from contextlib import contextmanager


def hp_client(system):
    client,data,job,headers=setup_reporter(system)
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute('UPDATE deployments SET selection_json=? WHERE id=?',(json.dumps({'hostname':'PC-LAB-01','settings':{'winget_packages':['hpia']}}),job['id']))
    return client,data,job,headers


def worker(client,data):
    headers=auth((data/'hp-repository'/'worker-key').read_text())
    body={'worker_id':str(uuid.uuid4()),'state':'ready'}
    assert client.post('/api/hp-repository/worker/heartbeat',headers=headers,json=body).status_code==200
    return headers,body


def write_snapshot(data,identifier,extra=None,platform='8AB8'):
    path=data/'hp-repository'/'snapshots'/(identifier+'.zip')
    with zipfile.ZipFile(path,'w') as archive:
        archive.writestr('.repository/cache/offline/platformList.cab',b'HP platform reference fixture')
        archive.writestr('.repository/cache/'+platform+'_64_11.0.25h2.cab',b'HP OS reference fixture')
        archive.writestr('sp12345.exe',b'Package fixture - not executable')
        archive.writestr('sp12345.cva',b'HP CVA fixture')
        if extra:archive.writestr(*extra)
    return path


def request_body(**overrides):return {'platform':'8ab8','os':'win11','os_version':'25H2','required_softpaqs':['SP12345'],**overrides}


def publish(client,data,request,headers):
    claimed=client.post('/api/hp-repository/worker/claim',json=request,headers=headers)
    assert claimed.status_code==200,claimed.text
    job=claimed.json()['job'];assert job
    path=write_snapshot(data,job['id'])
    finished=client.post('/api/hp-repository/worker/jobs/'+job['id']+'/finish',json={**request,'success':True},headers=headers)
    assert finished.status_code==200,finished.text
    return job,path


def test_queue_deduplicates_publishes_downloads_and_refreshes_missing_softpaq(system):
    client,data,job,headers=hp_client(system)
    route='/api/windows/'+job['id']+'/hp-repository'
    with ThreadPoolExecutor(max_workers=4) as pool:
        replies=list(pool.map(lambda _:client.post(route,headers=headers,json=request_body()),range(4)))
    assert all(r.status_code==200 and r.json()['status']=='queued' for r in replies)
    state=client.get('/api/hp-repository',headers=auth()).json()
    assert len(state['jobs'])==1 and not state['worker']['available']
    worker_headers,identity=worker(client,data)
    published,path=publish(client,data,identity,worker_headers)
    ready=client.post(route,headers=headers,json=request_body()).json()
    assert ready['status']=='ready' and ready['snapshot']['size']==path.stat().st_size
    assert ready['snapshot']['sha256']==hashlib.sha256(path.read_bytes()).hexdigest()
    assert client.get(ready['snapshot']['url'],headers=headers).content==path.read_bytes()
    assert client.get(ready['snapshot']['url']).status_code==401
    assert client.get(ready['snapshot']['url'],headers=auth(job['agent_token'])).status_code==401
    assert (data/'hp-repository'/'snapshots'/(published['id']+'.zip')).exists()
    # New recommendations trigger synchronization without changing a published ZIP.
    before=path.read_bytes()
    missing=client.post(route,headers=headers,json=request_body(required_softpaqs=['SP12345','SP99999'])).json()
    assert missing['status']=='queued' and missing['snapshot'] is None
    assert path.read_bytes()==before
    assert client.get(ready['snapshot']['url'],headers=headers).status_code==409
    state=client.get('/api/state',headers=auth()).json()['hp_repository']
    assert len(state['jobs'])==2 and len(state['snapshots'])==1
    assert worker_headers['Authorization'] not in json.dumps(state)


def test_repository_scope_expiry_validation_and_worker_ownership(system):
    client,data,job,headers=hp_client(system);route='/api/windows/'+job['id']+'/hp-repository'
    assert client.post(route,json=request_body()).status_code==401
    for body in [request_body(platform='../8ab8'),request_body(os_version='25H2;whoami'),request_body(required_softpaqs=['SP12345.exe;cmd']),{**request_body(),'url':'https://outside.invalid/package.exe'}]:
        assert client.post(route,headers=headers,json=body).status_code==422
    assert client.post(route,headers=headers,json=request_body()).status_code==200
    assert client.post(route,headers=headers,json=request_body(platform='8ABC')).status_code==409
    worker_headers,identity=worker(client,data)
    claimed=client.post('/api/hp-repository/worker/claim',json=identity,headers=worker_headers).json()['job']
    wrong={**identity,'worker_id':str(uuid.uuid4()),'success':True}
    assert client.post('/api/hp-repository/worker/jobs/'+claimed['id']+'/finish',json=wrong,headers=worker_headers).status_code==409
    assert client.post('/api/hp-repository/worker/heartbeat',json=identity,headers=auth()).status_code==401
    with sqlite3.connect(data/'deployment.sqlite3') as con:con.execute('UPDATE deployments SET report_expires=? WHERE id=?',('2000-01-01',job['id']))
    assert client.post(route,headers=headers,json=request_body()).status_code==401
    assert client.get('/api/hp-repository').status_code==401
    assert client.post('/api/hp-repository/refresh').status_code==401


def test_unchecked_hpia_cannot_queue_or_read_a_repository(system):
    client,data,job,headers=setup_reporter(system)
    assert client.post('/api/windows/'+job['id']+'/hp-repository',headers=headers,json=request_body()).status_code==403


@pytest.mark.parametrize('case',['private','traversal','script','duplicate','wrong_platform','symlink'])
def test_worker_cannot_publish_unsafe_or_wrong_repository(system,case):
    client,data,job,headers=hp_client(system)
    client.post('/api/windows/'+job['id']+'/hp-repository',headers=headers,json=request_body())
    wh,identity=worker(client,data)
    request=client.post('/api/hp-repository/worker/claim',headers=wh,json=identity).json()['job']
    entry={
        'private':('.repository/config.json','{"smtp_password":"not-public"}'),
        'traversal':('../sp12345.exe','bad'),
        'script':('sp12345.ps1','bad'),
        'duplicate':('SP12345.EXE','bad'),
    }.get(case)
    if case=='symlink':
        name=zipfile.ZipInfo('sp12346.exe');name.create_system=3;name.external_attr=0o120777<<16;entry=(name,'outside')
    write_snapshot(data,request['id'],entry,platform='8ABC' if case=='wrong_platform' else '8AB8')
    response=client.post('/api/hp-repository/worker/jobs/'+request['id']+'/finish',headers=wh,json={**identity,'success':True})
    assert response.status_code==422,response.text
    assert client.get('/api/hp-repository',headers=auth()).json()['snapshots']==[]


def test_failed_sync_cooldown_refresh_and_stale_snapshot_preserve_existing_files(system):
    client,data,job,headers=hp_client(system);route='/api/windows/'+job['id']+'/hp-repository'
    client.post(route,headers=headers,json=request_body());wh,identity=worker(client,data)
    published,path=publish(client,data,identity,wh)
    old=(datetime.now(timezone.utc)-timedelta(days=2)).isoformat()
    with sqlite3.connect(data/'deployment.sqlite3') as con:con.execute('UPDATE hp_repository_snapshots SET created_at=?',(old,))
    response=client.post(route,headers=headers,json=request_body()).json()
    assert response['status']=='queued' and response['snapshot'] is None
    claimed=client.post('/api/hp-repository/worker/claim',headers=wh,json=identity).json()['job']
    client.post('/api/hp-repository/worker/jobs/'+claimed['id']+'/finish',headers=wh,json={**identity,'success':False,'message':'HP network unavailable'})
    failed=client.post(route,headers=headers,json=request_body()).json()
    assert failed['status']=='failed' and 'unavailable' in failed['message']
    assert path.is_file()
    refreshed=client.post('/api/hp-repository/refresh',headers=auth()).json()
    assert len(refreshed['jobs'])==1
    state=client.get('/api/hp-repository',headers=auth()).json()
    assert len(state['snapshots'])==1 and len(state['jobs'])==3


def test_unavailable_softpaq_does_not_start_endless_synchronizations(system):
    client,data,job,headers=hp_client(system);route='/api/windows/'+job['id']+'/hp-repository'
    client.post(route,headers=headers,json=request_body(required_softpaqs=['SP99999']))
    wh,identity=worker(client,data);publish(client,data,identity,wh)
    for _ in range(3):
        response=client.post(route,headers=headers,json=request_body(required_softpaqs=['SP99999'])).json()
        assert response['status']=='unavailable' and response['snapshot'] is None
    assert len(client.get('/api/hp-repository',headers=auth()).json()['jobs'])==1


def test_retention_keeps_three_versions_and_archives_leased_by_a_client(system):
    client,data,job,headers=hp_client(system)
    @contextmanager
    def db(write=False):
        con=sqlite3.connect(data/'deployment.sqlite3');con.row_factory=sqlite3.Row
        try:yield con;con.commit()
        finally:con.close()
    repository=HpRepository(data,db);ids=[str(uuid.uuid4()) for _ in range(5)]
    for i,identifier in enumerate(ids):
        path=write_snapshot(data,identifier)
        created=(datetime.now(timezone.utc)-timedelta(days=5-i)).isoformat()
        with db(True) as con:con.execute('INSERT INTO hp_repository_snapshots VALUES (?,?,?,?,?,?,?,?)',(identifier,'8AB8','win11','25H2',hashlib.sha256(path.read_bytes()).hexdigest(),path.stat().st_size,'["SP12345"]',created))
    with db(True) as con:repository.lease(con,job['id'],ids[0])
    repository.prune()
    assert [p.stem for p in sorted((data/'hp-repository'/'snapshots').glob('*.zip'))]==sorted([ids[0],*ids[2:]])
    with db(True) as con:con.execute('UPDATE hp_repository_leases SET expires=?',('2000-01-01',))
    repository.prune()
    assert {p.stem for p in (data/'hp-repository'/'snapshots').glob('*.zip')}==set(ids[2:])


@pytest.mark.parametrize('case', ['valid', 'wrong_os', 'extra_package', 'missing_cva'])
def test_explicit_package_cache_preserves_real_windows_version_and_requires_capable_client(system, case):
    client, data, deployment, headers = hp_client(system)
    route = '/api/windows/' + deployment['id'] + '/hp-repository'
    body = request_body(os_version='26H2', package_cache=True)
    assert client.post(route, headers=headers, json=body).status_code == 200
    wh, identity = worker(client, data)
    job = client.post('/api/hp-repository/worker/claim', headers=wh, json=identity).json()['job']
    assert job['os_version'] == '26H2' and job['required_softpaqs'] == ['SP12345']
    marker = {'schema': 1, 'mode': 'packages_only', 'platform': '8AB8', 'os': 'win11',
              'os_version': '25H2' if case == 'wrong_os' else '26H2', 'softpaqs': ['SP12345']}
    path = data / 'hp-repository' / 'snapshots' / (job['id'] + '.zip')
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('.repository/cache/atelier-softpaq-cache.json', json.dumps(marker))
        archive.writestr('sp12345.exe', b'Fixture - never executed')
        if case != 'missing_cva':
            archive.writestr('sp12345.cva', b'HP CVA fixture')
        if case == 'extra_package':
            archive.writestr('sp99999.exe', b'Not selected')
    finished = client.post('/api/hp-repository/worker/jobs/' + job['id'] + '/finish', headers=wh,
                           json={**identity, 'success': True})
    assert finished.status_code == (200 if case == 'valid' else 422), finished.text
    if case == 'valid':
        result = client.post(route, headers=headers, json=body).json()
        assert result['status'] == 'ready' and result['os_version'] == '26H2'
        legacy = client.post(route, headers=headers, json={**body, 'package_cache': False}).json()
        assert legacy['status'] == 'unavailable' and legacy['snapshot'] is None
