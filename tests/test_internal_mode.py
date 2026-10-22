"""Internal-mode opt-in, MAC binding, expiry and automatic Windows defaults."""
import sqlite3
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app.main import create_app
from test_api import ADMIN, auth, prepare


def test_default_mode_remains_authenticated_and_discovery_disabled(tmp_path):
    with TestClient(create_app(tmp_path, ADMIN)) as client:
        assert client.get('/api/session').json() == {'internal_mode': False, 'automatic_windows': False}
        assert client.get('/api/state').status_code == 401
        assert client.post('/api/boot/discover', json={'macs':['00:11:22:33:44:55']}).status_code == 403


def test_internal_lifecycle_no_manual_secrets_and_scoped_share(tmp_path, monkeypatch):
    monkeypatch.setattr('app.main.read_share_credentials', lambda path: {'username':'SERVER\\AtelierPXERead', 'password':'test-only-secret'})
    with TestClient(create_app(tmp_path, ADMIN, 'https://192.168.99.250', internal_mode=True, automatic_windows=True)) as client:
        _, _, profile, payload = prepare(client, tmp_path)
        assert profile['settings']['unattended'] is True
        assert profile['settings']['windows_update'] is False
        assert profile['settings']['store_update'] is False
        payload.pop('confirmation')
        job = client.post('/api/deployments', json={**payload, 'wizard_enabled':True}).json()
        assert job['boot_code'] is None
        assert client.get('/api/state').status_code == 200
        assert client.post('/api/boot/discover', json={'macs':['00:11:22:33:44:66']}).status_code == 409
        connection = client.post('/api/boot/discover', json={'macs':['00-11-22-33-44-55']})
        assert connection.status_code == 200, connection.text
        session = connection.json()
        route = '/api/agent/' + job['id']
        assert session['plan']['internal_mode'] is True
        assert 'test-only-secret' not in connection.text
        assert client.get(route+'/share-credentials').status_code == 401
        assert client.get(route+'/share-credentials', headers=auth(job['agent_token'])).status_code == 401
        response = client.get(route+'/share-credentials', headers=auth(session['agent_token']))
        assert response.status_code == 200 and response.json()['password'] == 'test-only-secret'
        assert response.headers['cache-control'] == 'no-store'
        assert 'test-only-secret' not in client.get('/api/state').text
        assert client.post(route+'/claim', headers=auth(session['agent_token'])).status_code == 200
        assert client.post('/api/boot/discover', json={'macs':['00:11:22:33:44:55']}).status_code == 409
        assert client.post(route+'/events', headers=auth(session['agent_token']), json={'status':'staged','progress':100,'message':'done'}).status_code == 200
        assert client.get(route+'/share-credentials', headers=auth(session['agent_token'])).status_code == 409


def test_internal_origin_expiry_cancellation_and_secret_failure(tmp_path, monkeypatch):
    with TestClient(create_app(tmp_path, ADMIN, 'https://192.168.99.250', internal_mode=True)) as client:
        _, _, _, payload = prepare(client, tmp_path)
        assert client.get('/api/state', headers={'Origin':'https://external.example'}).status_code == 403
        assert client.get('/api/state', headers={'Sec-Fetch-Site':'cross-site'}).status_code == 403
        assert client.get('/api/state', headers={'Origin':'https://192.168.99.250'}).status_code == 200
        job = client.post('/api/deployments', json={**payload, 'wizard_enabled':True}).json()
        route = '/api/agent/'+job['id']
        response = client.get(route+'/share-credentials', headers=auth(job['agent_token']))
        assert response.status_code == 503
        assert 'internal-share.json' not in response.text
        with sqlite3.connect(tmp_path/'deployment.sqlite3') as con:
            con.execute('UPDATE deployments SET boot_code_expires=?', ((datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat(),))
        assert client.post('/api/boot/discover', json={'macs':['00:11:22:33:44:55']}).status_code == 409
        assert client.post('/api/deployments/'+job['id']+'/cancel').status_code == 200
        assert client.get(route+'/share-credentials', headers=auth(job['agent_token'])).status_code == 409


def test_share_secret_never_sent_over_http(tmp_path, monkeypatch):
    def forbidden(path):
        raise AssertionError('Secret reader must not be called over HTTP')
    monkeypatch.setattr('app.main.read_share_credentials', forbidden)
    with TestClient(create_app(tmp_path, ADMIN, internal_mode=True)) as client:
        _, _, _, payload = prepare(client, tmp_path)
        job = client.post('/api/deployments', json=payload).json()
        assert client.get('/api/agent/'+job['id']+'/share-credentials', headers=auth(job['agent_token'])).status_code == 403


def test_legacy_profiles_and_wizard_cannot_reenable_windows_or_store_updates(tmp_path):
    import json
    with TestClient(create_app(tmp_path, ADMIN, internal_mode=True, automatic_windows=True)) as client:
        _,_,profile,payload=prepare(client,tmp_path)
        settings={**profile['settings'],'windows_update':True,'store_update':True}
        with sqlite3.connect(tmp_path/'deployment.sqlite3') as con:
            con.execute('UPDATE profiles SET settings_json=? WHERE id=?',(json.dumps(settings),profile['id']))
        current=client.get('/api/state').json()['profiles'][0]['settings']
        assert current['windows_update'] is current['store_update'] is False
        job=client.post('/api/deployments',json={**payload,'wizard_enabled':True}).json()
        response=client.post('/api/agent/'+job['id']+'/configure',headers=auth(job['agent_token']),json={'profile_id':profile['id'],'hostname':'PC-LAB-01','settings':settings})
        assert response.status_code==200,response.text
        assert response.json()['settings']['windows_update'] is response.json()['settings']['store_update'] is False
        # An already saved sélection from an older client is also normalized.
        with sqlite3.connect(tmp_path/'deployment.sqlite3') as con:
            con.execute('UPDATE deployments SET selection_json=? WHERE id=?',(json.dumps({'profile_id':profile['id'],'hostname':'PC-LAB-01','settings':settings}),job['id']))
        plan=client.get('/api/agent/'+job['id']+'/plan',headers=auth(job['agent_token'])).json()
        assert plan['settings']['windows_update'] is plan['settings']['store_update'] is False
