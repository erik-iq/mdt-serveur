"""Cache KB authentifié, réutilisation et séparation des déploiements."""
import hashlib
import json
import sqlite3
import time
from pathlib import Path
import pytest
from test_api import auth, system
from test_reporting import setup_reporter

CONTEXT={'family':'11','release':'26H2','architecture':'x64','dotnet':'4.8.1','build':26300}


def wait(client,route,headers):
    for _ in range(100):
        value=client.get(route,headers=headers).json()
        if value['status'] not in ('queued','running'):return value
        time.sleep(.01)
    pytest.fail('Téléchargement simulé non terminé')


def fixture_prepare(calls,wrong_build=False,fail=False):
    def prepare(family,release,arch,dotnet,cache,**kwargs):
        calls.append((family,release,arch,dotnet))
        if fail:raise ValueError('Échec Microsoft simulé')
        cache=Path(cache);cache.mkdir(parents=True,exist_ok=True)
        raw=b'Microsoft MSU fixture, never installed'
        p=cache/'windows11.0-kb5127648-x64_abc.msu';p.write_bytes(raw)
        return {'family':family,'release':release,'architecture':arch,'dotnet':dotnet,'groups':[{
            'kind':'os','kb':'KB5127648','title':'Windows cumulative <fixture>','target_build':'26200.1' if wrong_build else '26300.9711',
            'files':[{'filename':p.name,'path':str(p),'url':'https://private-source-do-not-publish.test','sha256':hashlib.sha256(raw).hexdigest(),'size':len(raw)}]}]}
    return prepare


def test_cache_is_scoped_reused_and_does_not_expose_paths_or_source_urls(system,monkeypatch):
    client,data,job,headers=setup_reporter(system)
    calls=[];monkeypatch.setattr('app.windows_kb.prepare',fixture_prepare(calls))
    route='/api/windows/'+job['id']+'/kb'
    assert client.post(route,json=CONTEXT).status_code==401
    assert client.post(route,json=CONTEXT,headers=auth(job['agent_token'])).status_code==401
    value=client.post(route,json=CONTEXT,headers=headers).json()
    ready=wait(client,route+'/'+value['id'],headers)
    assert ready['status']=='ready',ready
    assert client.post(route,json=dict(CONTEXT,architecture='arm64'),headers=headers).status_code==409
    assert len(calls)==1
    assert client.post(route,json=CONTEXT,headers=headers).json()['id']==ready['id']
    public=json.dumps(ready)
    assert 'private-source' not in public and str(data) not in public and 'target_path' not in public
    file=ready['groups'][0]['files'][0]
    assert client.get(file['url']).status_code==401
    assert hashlib.sha256(client.get(file['url'],headers=headers).content).hexdigest()==file['sha256']
    # Un jeton valide d’un autre déploiement ne donne aucun accès à ce cache.
    other_machine=client.post('/api/machines',headers=auth(),json={'hostname':'OTHER-PC','mac':'00:11:22:33:44:66'}).json()
    profile=client.get('/api/state',headers=auth()).json()['profiles'][0]
    other=client.post('/api/deployments',headers=auth(),json={'machine_id':other_machine['id'],'profile_id':profile['id'],'confirmation':'EFFACER OTHER-PC'}).json()
    claim=client.post('/api/agent/'+other['id']+'/claim',headers=auth(other['agent_token'])).json()
    other_headers=auth(claim['report_token'])
    foreign=file['url'].replace(job['id'],other['id'])
    assert client.get(foreign,headers=other_headers).status_code==403
    overview=client.get('/api/maintenance/windows/kb',headers=auth())
    assert overview.status_code==200 and overview.json()['contexts']==[CONTEXT]
    assert client.get('/api/maintenance/windows/kb').status_code==401
    assert client.post('/api/maintenance/windows/kb/refresh').status_code==401
    refresh=client.post('/api/maintenance/windows/kb/refresh',headers=auth()).json()
    refreshed=wait(client,route+'/'+client.post(route,json=CONTEXT,headers=headers).json()['id'],headers)
    assert refreshed['status']=='ready'


@pytest.mark.parametrize('case',['wrong_build','download_failure','unsafe_context'])
def test_bad_catalog_or_context_cannot_be_ready(system,monkeypatch,case):
    client,data,job,headers=setup_reporter(system)
    calls=[];monkeypatch.setattr('app.windows_kb.prepare',fixture_prepare(calls,case=='wrong_build',case=='download_failure'))
    body=dict(CONTEXT)
    if case=='unsafe_context':body['release']='../../Windows'
    route='/api/windows/'+job['id']+'/kb'
    response=client.post(route,json=body,headers=headers)
    if case=='unsafe_context':assert response.status_code==422 and not calls;return
    value=response.json();result=wait(client,route+'/'+value['id'],headers)
    assert result['status']=='failed'
    assert not result['groups']
