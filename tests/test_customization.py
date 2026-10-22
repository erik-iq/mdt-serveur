"""Authorization, compatibility and migrations for the interactive PXE workflow."""
import hashlib
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import create_app, digest
from test_api import ADMIN, auth, prepare, register, system


def resource(client, data, filename, kind, content):
    (data / 'artifacts' / filename).write_bytes(content)
    result = client.post('/api/assets', headers=auth(), json={'filename': filename, 'kind': kind})
    assert result.status_code == 201, result.text
    return result.json()


def software(client, data, name='VLC', filename='vlc.exe', **extra):
    asset = resource(client, data, filename, 'application', b'synthetic unsigned installer')
    result = client.post('/api/applications', headers=auth(), json={
        'name': name, 'version': 'test', 'asset_id': asset['id'], **extra})
    assert result.status_code == 201, result.text
    return result.json(), asset


def connect(client, job, mac='00:11:22:33:44:55'):
    return client.post('/api/boot/connect', json={'code': job['boot_code'], 'macs': [mac]})


def test_bundle_deduplication_personalization_and_scoped_selection(system):
    client, data = system
    _, _, first, payload = prepare(client, data)
    app, _ = software(client, data)
    hp, _ = software(client, data, 'HP Image Assistant', 'hp.zip', manufacturer='hp',
                     install_mode='portable', entry_point='HPImageAssistant.exe')
    wallpaper = resource(client, data, 'desktop.png', 'wallpaper', b'\x89PNG\r\n\x1a\nfixture')
    bundle = client.post('/api/bundles', headers=auth(), json={'name': 'Atelier standard',
        'application_ids': [app['id'], hp['id']]}).json()
    settings = {**first['settings'], 'theme': 'dark', 'wallpaper_asset_id': wallpaper['id'],
                'application_ids': [app['id']], 'bundle_ids': [bundle['id']],
                'registered_owner': 'Équipe & IT', 'organization': 'Atelier'}
    profile = client.post('/api/profiles', headers=auth(), json={'name': 'Windows personnalise',
        'asset_id': first['asset_id'], 'windows_version': '26H2', 'edition': 'Pro', 'settings': settings}).json()
    job = client.post('/api/deployments', headers=auth(), json={**payload, 'wizard_enabled': True}).json()
    session = connect(client, job).json()
    route = '/api/agent/' + job['id']
    assert client.get(route+'/plan', headers=auth(job['agent_token'])).status_code == 401
    selected = {'profile_id': profile['id'], 'hostname': 'HP-ATELIER-01', 'settings': settings}
    result = client.post(route+'/configure', headers=auth(session['agent_token']), json=selected)
    assert result.status_code == 200, result.text
    plan = result.json()
    assert plan['hostname'] == 'HP-ATELIER-01' and plan['inventory_hostname'] == 'PC-LAB-01'
    assert plan['windows_version'] == '26H2' and plan['settings']['theme'] == 'dark'
    assert plan['wallpaper']['sha256'] == wallpaper['sha256']
    assert [a['id'] for a in plan['applications']] == [app['id'], hp['id']]
    assert plan['applications'][1]['manufacturer'] == 'hp'
    assert client.get('/boot/assets/'+wallpaper['id']).status_code == 403
    assert client.get('/boot/assets/'+app['asset_id']).status_code == 403
    assert client.post(route+'/claim', headers=auth(session['agent_token'])).status_code == 200
    assert connect(client, job).status_code == 401
    assert client.post(route+'/configure', headers=auth(session['agent_token']), json=selected).status_code == 409
    state = client.get('/api/state', headers=auth())
    assert state.json()['deployments'][0]['hostname'] == selected['hostname']
    for secret in (job['boot_code'], job['boot_code'].replace('-', ''), session['agent_token'], 'boot_code_hash', 'token_hash'):
        assert secret not in state.text


def test_boot_code_mac_expiry_rotation_and_cancellation(system):
    client, data = system
    _, _, _, payload = prepare(client, data)
    job = client.post('/api/deployments', headers=auth(), json={**payload, 'wizard_enabled': True}).json()
    assert len(job['boot_code'].replace('-', '')) == 20
    assert connect(client, job, '00:11:22:33:44:66').status_code == 403
    invalid = {**job, 'boot_code': 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ'}
    assert connect(client, invalid).status_code == 401
    first = connect(client, job).json()
    second = connect(client, job, '00-11-22-33-44-55').json()
    route = '/api/agent/' + job['id'] + '/plan'
    assert first['agent_token'] != second['agent_token']
    assert client.get(route, headers=auth(first['agent_token'])).status_code == 401
    assert client.get(route, headers=auth(second['agent_token'])).status_code == 200
    with sqlite3.connect(data / 'deployment.sqlite3') as con:
        con.execute('UPDATE deployments SET boot_code_expires=? WHERE id=?',
                    ((datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat(), job['id']))
    assert connect(client, job).status_code == 401
    assert client.post('/api/deployments/'+job['id']+'/cancel', headers=auth()).status_code == 200
    assert client.get(route, headers=auth(second['agent_token'])).status_code == 409


def test_catalogue_is_frozen_at_authorization(system):
    client, data = system
    _, _, profile, payload = prepare(client, data)
    job = client.post('/api/deployments', headers=auth(), json={**payload, 'wizard_enabled': True}).json()
    session = connect(client, job).json()
    later_app, _ = software(client, data)
    later_profile = client.post('/api/profiles', headers=auth(), json={'name':'Later', 'asset_id':profile['asset_id']}).json()
    route = '/api/agent/'+job['id']+'/configure'
    selection = {'profile_id': profile['id'], 'hostname': 'PC-LAB-01', 'settings': profile['settings']}
    assert client.post(route, headers=auth(session['agent_token']), json={**selection, 'profile_id':later_profile['id']}).status_code == 403
    assert client.post(route, headers=auth(session['agent_token']), json={**selection,
        'settings': {**selection['settings'], 'application_ids':[later_app['id']]}}).status_code == 403
    assert client.post(route, headers=auth(session['agent_token']), json=selection).status_code == 200


def test_text_jobs_remain_fixed_and_ignore_unselected_broken_software(system):
    client, data = system
    _, _, profile, payload = prepare(client, data)
    _, asset = software(client, data)
    (data / 'artifacts' / asset['filename']).unlink()
    result = client.post('/api/deployments', headers=auth(), json=payload)
    assert result.status_code == 201, result.text
    job = result.json()
    assert job['boot_code'] is None
    selection = {'profile_id':profile['id'], 'hostname':'OTHER', 'settings':profile['settings']}
    assert client.post('/api/agent/'+job['id']+'/configure', headers=auth(job['agent_token']), json=selection).status_code == 403


@pytest.mark.parametrize('kind', ['application', 'wallpaper'])
def test_changed_selected_resource_blocks_claim_before_disk_operations(system, kind):
    client, data = system
    _, _, profile, payload = prepare(client, data)
    settings = profile['settings']
    if kind == 'application':
        app, asset = software(client, data)
        settings['application_ids'] = [app['id']]
    else:
        asset = resource(client, data, 'desktop.jpg', 'wallpaper', b'\xff\xd8\xfffixture')
        settings['wallpaper_asset_id'] = asset['id']
    profile = client.post('/api/profiles', headers=auth(), json={'name':'With resource',
        'asset_id':profile['asset_id'], 'settings':settings}).json()
    job = client.post('/api/deployments', headers=auth(), json={**payload, 'profile_id':profile['id']}).json()
    (data / 'artifacts' / asset['filename']).write_bytes(b'changed after authorization')
    result = client.post('/api/agent/'+job['id']+'/claim', headers=auth(job['agent_token']))
    assert result.status_code == 409
    assert client.get('/api/state', headers=auth()).json()['deployments'][0]['status'] == 'queued'


def test_no_cross_job_token_or_hostname_collision(system):
    client, data = system
    _, _, profile, payload = prepare(client, data)
    first = client.post('/api/deployments', headers=auth(), json={**payload, 'wizard_enabled':True}).json()
    machine = client.post('/api/machines', headers=auth(), json={'hostname':'PC-LAB-02', 'mac':'00:11:22:33:44:66'}).json()
    second = client.post('/api/deployments', headers=auth(), json={**payload, 'machine_id':machine['id'],
        'confirmation':'EFFACER PC-LAB-02', 'wizard_enabled':True}).json()
    route = '/api/agent/'+second['id']+'/configure'
    selection = {'profile_id':profile['id'], 'hostname':'PC-LAB-01', 'settings':profile['settings']}
    assert client.post(route, headers=auth(first['agent_token']), json=selection).status_code == 401
    assert client.post(route, headers=auth(second['agent_token']), json=selection).status_code == 409
    selection['hostname'] = 'NEW-NAME'
    assert client.post('/api/agent/'+first['id']+'/configure', headers=auth(first['agent_token']), json=selection).status_code == 200
    assert client.post(route, headers=auth(second['agent_token']), json=selection).status_code == 409


@pytest.mark.parametrize('bad', [
    {'entry_point':'../escape.exe'}, {'entry_point':'C:/tools/run.exe'},
    {'entry_point':'tools//run.exe'}, {'entry_point':'run.ps1'},
    {'entry_point':'run.exe', 'install_mode':'portable', 'arguments':'/flash'},
])
def test_unsafe_portable_metadata_rejected(system, bad):
    client, data = system
    asset = resource(client, data, 'tools.zip', 'application', b'synthetic archive')
    result = client.post('/api/applications', headers=auth(), json={'name':'Tools', 'asset_id':asset['id'], **bad})
    assert result.status_code in {400,422}


def test_invalid_setting_and_wrong_resource_kind_rejected(system):
    client, data = system
    asset, _, profile, _ = prepare(client, data)
    for settings in ({'timezone':'Invalid timezone'}, {'keyboard':'malicious'}, {'organization':'line\nline'}):
        assert client.post('/api/profiles', headers=auth(), json={'name':'Invalid', 'asset_id':asset['id'], 'settings':settings}).status_code == 422
    assert client.post('/api/profiles', headers=auth(), json={'name':'Wrong kind', 'asset_id':asset['id'],
        'settings':{'wallpaper_asset_id':asset['id']}}).status_code == 400
    assert client.post('/api/bundles', headers=auth(), json={'name':'Missing', 'application_ids':['missing']}).status_code == 404
    assert client.post('/api/assets', headers=auth(), json={'filename':'install.wim','kind':'wallpaper'}).status_code == 400
    assert profile['settings']['keyboard'] == '040c:0000040c'


def test_real_v01_database_migration_preserves_existing_authorization(tmp_path):
    """Use the old schéma, rather than a database already migrated by this version."""
    artifacts = tmp_path / 'artifacts'
    artifacts.mkdir()
    content = b'MSWIM\0\0\0legacy-fixture'
    image = artifacts / 'old.wim'
    image.write_bytes(content)
    stat = image.stat()
    timestamp = datetime.now(timezone.utc).isoformat()
    old_agent = 'legacy-scoped-token-at-least-32-characters'
    with sqlite3.connect(tmp_path / 'deployment.sqlite3') as con:
        con.executescript('''
            CREATE TABLE machines(id TEXT PRIMARY KEY, hostname TEXT NOT NULL UNIQUE COLLATE NOCASE, mac TEXT NOT NULL UNIQUE, description TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE assets(id TEXT PRIMARY KEY, filename TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE profiles(id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, asset_id TEXT NOT NULL REFERENCES assets(id), image_index INTEGER NOT NULL, locale TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE deployments(id TEXT PRIMARY KEY, machine_id TEXT NOT NULL REFERENCES machines(id), profile_id TEXT NOT NULL REFERENCES profiles(id), disk_number INTEGER NOT NULL, token_hash TEXT NOT NULL, status TEXT NOT NULL, progress INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
            CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, deployment_id TEXT NOT NULL REFERENCES deployments(id), status TEXT NOT NULL, progress INTEGER NOT NULL, message TEXT NOT NULL, created_at TEXT NOT NULL);
        ''')
        con.execute('INSERT INTO machines VALUES (?,?,?,?,?)', ('machine','OLD-PC','00:11:22:33:44:55','Legacy',timestamp))
        con.execute('INSERT INTO assets VALUES (?,?,?,?,?,?,?)', ('image','old.wim','windows',hashlib.sha256(content).hexdigest(),stat.st_size,stat.st_mtime_ns,timestamp))
        con.execute('INSERT INTO profiles VALUES (?,?,?,?,?,?)', ('profile','Old Windows','image',2,'en-US',timestamp))
        con.execute('INSERT INTO deployments VALUES (?,?,?,?,?,?,?,?,?)', ('job','machine','profile',0,digest(old_agent),'queued',0,timestamp,timestamp))
    for _ in range(2):  # Repeated startup must keep the migrated data and token valid.
        with TestClient(create_app(tmp_path, ADMIN)) as client:
            state = client.get('/api/state', headers=auth()).json()
            assert len(state['deployments']) == 1 and state['applications'] == []
            plan = client.get('/api/agent/job/plan', headers=auth(old_agent)).json()
            assert plan['hostname'] == 'OLD-PC' and plan['image_index'] == 2
            assert plan['settings']['keyboard'] == '0409:00000409'
            assert plan['wizard_enabled'] is False and plan['applications'] == []
    with TestClient(create_app(tmp_path, ADMIN)) as client:
        assert client.post('/api/agent/job/claim', headers=auth(old_agent)).status_code == 200
