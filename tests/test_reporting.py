"""Post-boot credentials must never regain WinPE deployment capabilities."""
import json
import sqlite3

from test_api import auth, prepare, system  # shared isolated console fixture
from app.reports import make_pdf


def setup_reporter(system):
    client, data = system
    _, _, _, payload = prepare(client, data)
    job = client.post('/api/deployments', json=payload, headers=auth()).json()
    route = '/api/agent/' + job['id']
    claimed = client.post(route + '/claim', headers=auth(job['agent_token'])).json()
    return client, data, job, auth(claimed['report_token'])


def snapshot(**overrides):
    return dict(hostname='PC-LAB-01', status='completed', generated_at='2026-10-15T16:00:00Z',
                inventory={'Modèle': 'HP (EliteBook) \\ test', 'Windows': 'Windows 11 Pro'},
                steps=[dict(name='Windows Update', status='completed', message='KB test installée')],
                warnings=['Microsoft Store : achèvement non vérifié'], **overrides)


def test_report_after_staged_is_authorized_scoped_and_visible_on_machine(system):
    client, data, job, headers = setup_reporter(system)
    agent = '/api/agent/' + job['id']
    windows = '/api/windows/' + job['id']
    assert client.post(agent + '/events', json={'status':'staged','progress':100,'message':'ready'}, headers=auth(job['agent_token'])).status_code == 200
    assert client.get(agent + '/plan', headers=headers).status_code == 401
    assert client.get(agent + '/plan', headers=auth(job['agent_token'])).status_code == 409
    assert client.post(windows + '/report', json=snapshot(), headers=auth(job['agent_token'])).status_code == 401
    assert client.post(windows + '/progress', json={'status':'running','progress':80,'message':'Téléchargement KB'}, headers=headers).status_code == 200
    assert client.post(windows + '/report', json=snapshot(), headers=headers).status_code == 200
    state = client.get('/api/state', headers=auth()).json()
    assert state['deployments'][0]['windows_status'] == 'completed'
    assert state['reports'][0]['machine_id'] == state['machines'][0]['id']
    assert job['agent_token'] not in json.dumps(state) and headers['Authorization'] not in json.dumps(state)
    pdf = '/api/deployments/' + job['id'] + '/report.pdf'
    assert client.get(pdf).status_code == 401
    result = client.get(pdf, headers=auth())
    assert result.content.startswith(b'%PDF-1.4') and b'%%EOF' in result.content
    assert b'HISTORIQUE WINPE' in result.content
    assert result.headers['content-type'] == 'application/pdf'
    # Retrying the same final report is idempotent; running cannot overwrite it.
    assert client.post(windows + '/report', json=snapshot(), headers=headers).status_code == 200
    assert client.post(windows + '/progress', json={'status':'running','progress':10,'message':'stale'}, headers=headers).status_code == 409


def test_report_expiry_identity_limits_and_cancellation(system):
    client, data, job, headers = setup_reporter(system)
    route = '/api/windows/' + job['id']
    wrong = snapshot(); wrong['hostname'] = 'ANOTHER-PC'
    assert client.post(route + '/report', json=wrong, headers=headers).status_code == 409
    large = snapshot(); large['inventory']['data'] = 'x' * 140000
    assert client.post(route + '/report', json=large, headers=headers).status_code == 413
    with sqlite3.connect(data / 'deployment.sqlite3') as con:
        con.execute('UPDATE deployments SET report_expires=? WHERE id=?', ('2000-01-01', job['id']))
    assert client.post(route + '/report', json=snapshot(), headers=headers).status_code == 401


def test_pdf_pagination_escaping_and_byte_offsets():
    result = make_pdf(['État (à vérifier) \\ test', *['Une ligne' for _ in range(130)]])
    assert b'/Count 3' in result and b'\\(' in result and b'\\\\' in result
    start = int(result.split(b'startxref\n')[1].splitlines()[0])
    assert result[start:].startswith(b'xref\n')
    entries = result[start:].splitlines()[3:]
    for index, entry in enumerate(entries, 1):
        if not entry.endswith(b' n '):
            break
        offset = int(entry[:10])
        assert result[offset:].startswith(f'{index} 0 obj'.encode())
