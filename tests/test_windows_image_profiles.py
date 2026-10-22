"""A serviced WIM never changes production until its actual test jobs pass."""
from concurrent.futures import ThreadPoolExecutor
import json
import sqlite3

import pytest

from scripts import windows_image_profiles as workflow
from test_api import auth
from test_atelier3 import automatic


def candidate(data, source_id):
    source = workflow.sources(data)[0]
    folder = data / 'windows-servicing' / 'runs' / '20261020-120000-test0001'
    folder.mkdir(parents=True)
    image = folder / 'candidate.wim'
    image.write_bytes(b'MSWIM\0\0\0' + b'patched WIM fixture')
    report = dict(schema=1, run_id=folder.name, status='ready_for_test', source_asset_id=source_id,
                  source_sha256=source['sha256'], candidate_path=str(image),
                  candidate_sha256=workflow.file_hash(image), indexes=[{'index': 1}, {'index': 2}])
    path = folder / 'report.json'
    path.write_text(json.dumps(report))
    return path


def test_job(client, profile, serial, completed=True):
    session = client.post('/api/boot/discover', json={'release': 'ATELIER-4', 'serial_number': serial}).json()
    route = '/api/agent/' + session['id']
    selected = client.post(route + '/configure', headers=auth(session['agent_token']),
        json={'profile_id': profile['id'], 'hostname': 'PC-' + serial[-4:], 'settings': profile['settings'], 'disk_number': 0})
    assert selected.status_code == 200, selected.text
    claim = client.post(route + '/claim', headers=auth(session['agent_token'])).json()
    assert client.post(route + '/events', headers=auth(session['agent_token']),
        json={'status': 'staged', 'progress': 100, 'message': 'Fixture image staged'}).status_code == 200
    status = 'completed' if completed else 'needs_attention'
    assert client.post('/api/windows/' + session['id'] + '/progress', headers=auth(claim['report_token']),
        json={'status': status, 'progress': 100, 'message': 'Fixture Windows result'}).status_code == 200
    return session['id']


def register(automatic):
    client, data, pro, home = automatic
    source = workflow.sources(data)[0]
    path = candidate(data, source['id'])
    result = workflow.register_test(data, path)
    profiles = {profile['id']: profile for profile in client.get('/api/state').json()['profiles']}
    tests = [profiles[item['test_profile_id']] for item in result['test_profiles']]
    return client, data, pro, home, path, result, tests


def test_register_is_idempotent_and_tests_never_become_auto_selected(automatic):
    client, data, pro, home, path, result, tests = register(automatic)
    assert workflow.register_test(data, path)['asset_id'] == result['asset_id']
    response = client.post('/api/boot/discover', json={'release': 'ATELIER-4', 'serial_number': 'NEW-PC-1234'})
    assert response.status_code == 200
    assert response.json()['plan']['profile_id'] == pro['id']
    assert {p['id'] for p in tests} <= {p['id'] for p in response.json()['catalog']['profiles']}
    assert all(p['asset_id'] == result['asset_id'] for p in tests)
    assert all(p['image_test'] for p in tests)
    assert {p['edition'] for p in tests} == {'Pro', 'Famille'}
    assert len(workflow.sources(data)) == 1
    assert client.post('/api/profiles', json={'name': 'Bypass test', 'asset_id': result['asset_id']}).status_code == 409
    assert next(a for a in client.get('/api/state').json()['assets'] if a['id'] == result['asset_id'])['image_validation'] == 'testing'
    with workflow.database(data) as con:
        assert con.execute('SELECT asset_id FROM profiles WHERE id=?', (pro['id'],)).fetchone()[0] != result['asset_id']


def test_only_publish_after_successful_windows_for_each_used_index_preserving_settings_and_history(automatic):
    client, data, pro, home, path, result, tests = register(automatic)
    ids = [test_job(client, profile, 'SERIAL-' + str(1000 + i)) for i, profile in enumerate(tests)]
    with pytest.raises(ValueError, match='chaque index'):
        workflow.promote(data, result['run_id'], ids[:1])
    published = workflow.promote(data, result['run_id'], ids)
    assert published['status'] == 'published'
    assert workflow.promote(data, result['run_id'], [])['already_published']
    state = client.get('/api/state').json()
    for original in (pro, home):
        updated = next(p for p in state['profiles'] if p['id'] == original['id'])
        assert updated['asset_id'] == result['asset_id']
        for key in ('name', 'image_index', 'locale', 'settings', 'edition'):
            assert updated[key] == original[key]
    assert len(state['deployments']) == 2
    assert len(workflow.status(data, result['run_id'])[0]['test_deployments']) == 2
    assert len(state['assets']) == 2
    assert len(workflow.sources(data)) == 1 and workflow.sources(data)[0]['id'] == result['asset_id']


@pytest.mark.parametrize('case', ['incomplete', 'foreign', 'active', 'tampered', 'changed_profile'])
def test_rejected_publications_are_atomic_and_keep_original_profiles(automatic, case):
    client, data, pro, home, path, result, tests = register(automatic)
    ids = [test_job(client, p, 'SERIAL-' + str(1000 + i), completed=case != 'incomplete') for i, p in enumerate(tests)]
    if case == 'foreign':
        ids[0] = test_job(client, pro, 'PRODUCTION-5555')
    if case == 'active':
        client.post('/api/boot/discover', json={'release': 'ATELIER-4', 'serial_number': 'ACTIVE-9999'})
    if case == 'tampered':
        (data / 'artifacts' / ('windows-test-' + result['run_id'] + '.wim')).write_bytes(b'corrupt')
    if case == 'changed_profile':
        with workflow.database(data, write=True) as con:
            con.execute('UPDATE profiles SET image_index=3 WHERE id=?', (home['id'],))
    with pytest.raises(ValueError):
        workflow.promote(data, result['run_id'], ids)
    with workflow.database(data) as con:
        assert {r[0] for r in con.execute('SELECT asset_id FROM profiles WHERE id IN (?,?)', (pro['id'], home['id']))} == {pro['asset_id']}
        assert con.execute('SELECT status FROM windows_image_candidates').fetchone()[0] == 'testing'


def test_concurrent_registration_creates_one_asset_and_profile_set(automatic):
    _, data, pro, _ = automatic
    path = candidate(data, pro['asset_id'])
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: workflow.register_test(data, path), range(2)))
    assert len({r['asset_id'] for r in results}) == 1
    with workflow.database(data) as con:
        assert con.execute('SELECT COUNT(*) FROM assets').fetchone()[0] == 2
        assert con.execute('SELECT COUNT(*) FROM windows_image_test_profiles').fetchone()[0] == 2
    assert not list((data / 'artifacts').glob('*.partial-*'))


def test_tampered_candidate_never_registers_and_missing_database_is_not_created(tmp_path, automatic):
    _, data, pro, _ = automatic
    path = candidate(data, pro['asset_id'])
    (path.parent / 'candidate.wim').write_bytes(b'corrupt')
    with pytest.raises(ValueError, match='modifie'):
        workflow.register_test(data, path)
    with pytest.raises(ValueError, match='absente'):
        workflow.sources(tmp_path / 'missing')
    assert not (tmp_path / 'missing' / 'deployment.sqlite3').exists()


@pytest.mark.parametrize('status', ['cancelled', 'cancelled_cleanup_required'])
def test_cancelled_preparations_never_create_test_profiles_or_replace_production(automatic, status):
    _, data, pro, _ = automatic
    path = candidate(data, pro['asset_id'])
    report = json.loads(path.read_text())
    report['status'] = status
    path.write_text(json.dumps(report))
    with pytest.raises(ValueError, match='non prête'):
        workflow.register_test(data, path)
    with workflow.database(data) as con:
        assert con.execute('SELECT COUNT(*) FROM windows_image_candidates').fetchone()[0] == 0
        assert con.execute('SELECT asset_id FROM profiles WHERE id=?', (pro['id'],)).fetchone()[0] == pro['asset_id']


# Helper name must not be collected as a test.
test_job.__test__ = False


def test_reduced_wim_remaps_indexes_and_keeps_other_editions_on_original_image(automatic):
    client, data, pro, home = automatic
    with workflow.database(data, write=True) as con:
        con.execute('UPDATE profiles SET image_index=6 WHERE id=?', (pro['id'],))
        con.execute('UPDATE profiles SET image_index=1 WHERE id=?', (home['id'],))
    other = client.post('/api/profiles', json={'name':'Éducation conservée', 'asset_id':pro['asset_id'],
        'image_index':3, 'edition':'Éducation'}).json()
    path = candidate(data, pro['asset_id'])
    report = json.loads(path.read_text())
    report.update(schema=2, scope='home_pro', indexes=[{'source_index':1,'index':1}, {'source_index':6,'index':2}])
    path.write_text(json.dumps(report))
    result = workflow.register_test(data, path)
    profiles = {p['id']:p for p in client.get('/api/state').json()['profiles']}
    tests = [profiles[m['test_profile_id']] for m in result['test_profiles']]
    assert {(p['edition'],p['image_index']) for p in tests} == {('Pro',2),('Famille',1)}
    ids = [test_job(client, p, 'REMAP-'+str(1000+i)) for i,p in enumerate(tests)]
    workflow.promote(data, result['run_id'], ids)
    profiles = {p['id']:p for p in client.get('/api/state').json()['profiles']}
    assert profiles[pro['id']]['image_index'] == 2
    assert profiles[home['id']]['image_index'] == 1
    assert profiles[other['id']]['asset_id'] == pro['asset_id']
    assert profiles[other['id']]['image_index'] == 3
    assert workflow.sources(data)[0]['id'] == result['asset_id']
    for original in (pro,home):
        assert profiles[original['id']]['settings'] == original['settings']


@pytest.mark.parametrize('indexes', [[{'source_index':1,'index':1},{'source_index':2,'index':1}],
    [{'source_index':1,'index':1},{'source_index':1,'index':2}], [{'source_index':2,'index':0}]])
def test_invalid_reduced_index_mapping_cannot_register(automatic, indexes):
    _, data, pro, _ = automatic
    path = candidate(data, pro['asset_id'])
    report = json.loads(path.read_text());report.update(scope='home_pro',indexes=indexes)
    path.write_text(json.dumps(report))
    with pytest.raises(ValueError,match='Correspondance'):
        workflow.register_test(data,path)
