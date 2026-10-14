import hashlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from fastapi.testclient import TestClient
import pytest

from app.main import create_app

ADMIN = 'test-only-administrator-token-00000000'


@pytest.fixture
def system(tmp_path):
    app = create_app(tmp_path, ADMIN, 'https://192.168.99.2')
    with TestClient(app) as client:
        yield client, tmp_path


def auth(token=ADMIN):
    return {'Authorization': 'Bearer ' + token}


def register(client, data, filename='install.wim', kind='windows'):
    # Synthetic WIM-header fixture tests the control plane, never DISM.
    content = b'MSWIM\0\0\0' + b'fixture-not-a-deployable-image' * 30
    (data / 'artifacts' / filename).write_bytes(content)
    response = client.post('/api/assets', json={'filename': filename, 'kind': kind}, headers=auth())
    assert response.status_code == 201, response.text
    assert response.json()['sha256'] == hashlib.sha256(content).hexdigest()
    return response.json()


def prepare(client, data):
    asset = register(client, data)
    machine = client.post('/api/machines', json={'hostname': 'PC-LAB-01', 'mac': '00-11-22-33-44-55'}, headers=auth()).json()
    profile = client.post('/api/profiles', json={'name': 'Windows test', 'asset_id': asset['id']}, headers=auth()).json()
    payload = {'machine_id': machine['id'], 'profile_id': profile['id'], 'disk_number': 0, 'confirmation': 'EFFACER PC-LAB-01'}
    return asset, machine, profile, payload


def test_authentication_and_no_secret_in_state(system):
    client, data = system
    assert client.get('/health').json()['status'] == 'ok'
    assert client.get('/api/state').status_code == 401
    assert client.get('/api/state', headers=auth('invalid')).status_code == 401
    _, _, _, payload = prepare(client, data)
    job = client.post('/api/deployments', json=payload, headers=auth()).json()
    result = client.get('/api/state', headers=auth())
    assert result.status_code == 200
    assert 'token_hash' not in result.text and job['agent_token'] not in result.text
    assert result.headers['cache-control'] == 'no-store'


def test_complete_agent_lifecycle_and_terminal_revocation(system):
    client, data = system
    asset, _, _, payload = prepare(client, data)
    result = client.post('/api/deployments', json=payload, headers=auth())
    assert result.status_code == 201
    job = result.json()
    route = '/api/agent/' + job['id']
    headers = auth(job['agent_token'])
    assert client.get(route+'/plan', headers=auth()).status_code == 401
    plan = client.get(route+'/plan', headers=headers).json()
    assert plan['mac'] == '00:11:22:33:44:55' and plan['image_sha256'] == asset['sha256']
    image = client.get(route+'/image', headers=headers)
    assert hashlib.sha256(image.content).hexdigest() == asset['sha256']
    assert client.post(route+'/events', headers=headers, json={'status':'staged','progress':100,'message':'too early'}).status_code == 409
    assert client.post(route+'/claim', headers=headers).status_code == 200
    assert client.post(route+'/claim', headers=headers).status_code == 409
    for percent in (5, 20, 35, 80):
        assert client.post(route+'/events', headers=headers, json={'status':'running','progress':percent,'message':'Step'}).status_code == 200
    assert client.post(route+'/events', headers=headers, json={'status':'running','progress':20,'message':'backwards'}).status_code == 409
    assert client.post(route+'/events', headers=headers, json={'status':'staged','progress':99,'message':'incomplete'}).status_code == 409
    assert client.post(route+'/events', headers=headers, json={'status':'staged','progress':100,'message':'image prepared, first boot unverified'}).status_code == 200
    assert client.get(route+'/plan', headers=headers).status_code == 409
    assert client.get(route+'/image', headers=headers).status_code == 409
    events = client.get('/api/deployments/'+job['id']+'/events', headers=auth()).json()
    assert len(events) == 7 and events[-1]['status'] == 'staged'


def test_explicit_authorization_duplicate_jobs_and_cancellation(system):
    client, data = system
    _, _, _, payload = prepare(client, data)
    wrong = {**payload, 'confirmation':'oui'}
    assert client.post('/api/deployments', json=wrong, headers=auth()).status_code == 400
    job = client.post('/api/deployments', json=payload, headers=auth()).json()
    assert client.post('/api/deployments', json=payload, headers=auth()).status_code == 409
    assert client.post('/api/deployments/'+job['id']+'/cancel', headers=auth()).status_code == 200
    assert client.get('/api/agent/'+job['id']+'/plan', headers=auth(job['agent_token'])).status_code == 409
    assert client.post('/api/deployments', json=payload, headers=auth()).status_code == 201


def test_concurrent_authorizations_only_one_active_job(system):
    client, data = system
    _, _, _, payload = prepare(client, data)
    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(pool.map(lambda _: client.post('/api/deployments', json=payload, headers=auth()).status_code, range(2)))
    assert sorted(statuses) == [201, 409]


def test_concurrent_agent_claim_and_failure_revocation(system):
    client, data = system
    _, _, _, payload = prepare(client, data)
    job = client.post('/api/deployments', json=payload, headers=auth()).json()
    route = '/api/agent/' + job['id']
    headers = auth(job['agent_token'])
    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(pool.map(lambda _: client.post(route+'/claim', headers=headers).status_code, range(2)))
    assert sorted(statuses) == [200, 409]
    assert client.post(route+'/events', headers=headers, json={'status':'failed','progress':0,'message':'Image rejected before disk wipe'}).status_code == 200
    assert client.get(route+'/plan', headers=headers).status_code == 409
    assert client.get('/api/state', headers=auth()).json()['totals']['active'] == 0


@pytest.mark.parametrize('mac', ['ZZ:11:22:33:44:55', '01:11:22:33:44:55', '00:00:00:00:00:00'])
def test_invalid_machine_identity(system, mac):
    client, _ = system
    assert client.post('/api/machines', json={'hostname':'PC-01', 'mac':mac}, headers=auth()).status_code == 422


def test_path_traversal_and_symlinks_rejected(system):
    client, data = system
    assert client.post('/api/assets', json={'filename':'../secret', 'kind':'windows'}, headers=auth()).status_code == 422
    outside = data / 'secret.wim'
    outside.write_bytes(b'MSWIM\0\0\0')
    (data / 'artifacts' / 'link.wim').symlink_to(outside)
    assert client.post('/api/assets', json={'filename':'link.wim','kind':'windows'}, headers=auth()).status_code == 400


def test_changed_image_rejected_before_job(system):
    client, data = system
    _, _, _, payload = prepare(client, data)
    (data / 'artifacts' / 'install.wim').write_bytes(b'MSWIM\0\0\0CHANGED')
    assert client.post('/api/deployments', json=payload, headers=auth()).status_code == 409


def test_image_cannot_be_served_as_public_boot_file(system):
    client, data = system
    asset = register(client, data)
    assert client.get('/boot/assets/'+asset['id']).status_code == 403
    assert client.get('/boot/menu.ipxe').status_code == 503


def test_ipxe_boot_menu_and_public_boot_files(system):
    client, data = system
    for kind, name in [('wimboot','wimboot'),('bcd','BCD'),('sdi','boot.sdi'),('winpe','boot.wim')]:
        asset = register(client, data, name, kind)
        assert client.get('/boot/assets/'+asset['id']).status_code == 200
    response = client.get('/boot/menu.ipxe')
    assert response.status_code == 200
    assert response.text.startswith('#!ipxe\n') and 'https://192.168.99.2/boot/assets/' in response.text
    assert 'choose --default local' in response.text
    assert 'agent_token' not in response.text


def test_database_survives_restart_and_generated_token_is_private(tmp_path):
    app = create_app(tmp_path, base_url='http://127.0.0.1:8080')
    token_file = tmp_path / 'admin-token'
    assert token_file.stat().st_mode & 0o777 == 0o600
    token = token_file.read_text()
    with TestClient(app) as client:
        assert client.post('/api/machines', json={'hostname':'PC-01','mac':'00:11:22:33:44:55'}, headers=auth(token)).status_code == 201
    with TestClient(create_app(tmp_path)) as client:
        assert len(client.get('/api/state', headers=auth(token)).json()['machines']) == 1


def test_frontend_headers_and_validation(system):
    client, _ = system
    response = client.get('/')
    assert response.status_code == 200 and 'Atelier PXE' in response.text
    assert "script-src 'self'" in response.headers['content-security-policy']
    assert client.get('/static/app.js').status_code == 200
    assert client.get('/winpe/Deploy.ps1').status_code == 200
    assert client.post('/api/profiles', headers=auth(), json={'name':'x','asset_id':'missing'}).status_code == 404


@pytest.mark.parametrize('url', ['http://example.com/path', 'https://user:password@example.com', "https://example.com'", 'file:///tmp'])
def test_invalid_public_origin_rejected(tmp_path, url):
    with pytest.raises(ValueError):
        create_app(tmp_path, ADMIN, url)
