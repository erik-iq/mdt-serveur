"""Physical serial identity, shared docks, scoped sessions and old SQLite history."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import sqlite3
from datetime import datetime,timezone

from fastapi.testclient import TestClient
import pytest

from app.main import create_app,digest
from test_api import ADMIN,auth,register,system
from test_atelier3 import automatic


def boot(client,serial,macs=None):
    return client.post('/api/boot/discover',json={'release':'ATELIER-4','serial_number':serial,'macs':macs or []})


def test_same_serial_across_docks_or_without_visible_mac_reuses_one_machine_and_job(automatic):
    client,_,_,_=automatic
    one=boot(client,' hp-ABC1234 ',['00:11:22:33:44:55']).json()
    two=boot(client,'HP-ABC1234',['00:11:22:33:44:66']).json()
    three=boot(client,'HP-ABC1234').json()
    assert one['id']==two['id']==three['id']
    assert three['plan']['serial_number']=='HP-ABC1234'
    state=client.get('/api/state').json()
    assert len(state['machines'])==len(state['deployments'])==1
    assert state['machines'][0]['mac']=='00:11:22:33:44:66'
    assert 'legacy_mac_key' not in json.dumps(state)
    assert client.get('/api/agent/'+one['id']+'/plan',headers=auth(one['agent_token'])).status_code==401
    assert client.get('/api/agent/'+three['id']+'/plan',headers=auth(three['agent_token'])).status_code==200


def test_two_pcs_on_same_dock_have_separate_histories_and_no_legacy_mac_takeover(automatic):
    client,_,_,_=automatic
    one=boot(client,'HP-PC-0001',['00:11:22:33:44:55'])
    two=boot(client,'HP-PC-0002',['00:11:22:33:44:55'])
    assert one.status_code==two.status_code==200
    assert one.json()['id']!=two.json()['id']
    state=client.get('/api/state').json()
    assert len(state['machines'])==2 and {m['serial_number'] for m in state['machines']}=={'HP-PC-0001','HP-PC-0002'}
    assert client.post('/api/boot/discover',json={'release':'ATELIER-4','macs':['00:11:22:33:44:55']}).status_code==409
    for machine in state['machines']:
        detail=client.get('/api/machines/'+machine['id']+'/details').json()
        assert detail['total']==1 and 'legacy_mac_key' not in detail['machine']


def test_concurrent_serial_arrivals_rotate_one_job_even_with_two_network_interfaces(automatic):
    client,_,_,_=automatic
    with ThreadPoolExecutor(max_workers=2) as pool:
        sessions=list(pool.map(lambda mac:boot(client,'HP-SAME-0001',[mac]).json(),['00:11:22:33:44:55','00:11:22:33:44:66']))
    assert sessions[0]['id']==sessions[1]['id']
    assert sorted(client.get('/api/agent/'+s['id']+'/plan',headers=auth(s['agent_token'])).status_code for s in sessions)==[200,401]


@pytest.mark.parametrize('serial',['','Unknown','Not Available','To Be Filled By O.E.M.','Default string','00000000','FFFFFFFF','A\x01B123','X'*81])
def test_missing_or_generic_serial_cannot_create_an_empty_or_shared_identity(automatic,serial):
    client,_,_,_=automatic
    assert boot(client,serial).status_code==422
    assert client.get('/api/state').json()['machines']==[]


def test_serial_bound_code_accepts_dock_change_but_refuses_another_pc_with_same_mac(system):
    client,data=system
    asset=register(client,data)
    machine=client.post('/api/machines',headers=auth(),json={'hostname':'PC-SERIAL','serial_number':'HP-TEST-1234','mac':'00:11:22:33:44:55'}).json()
    profile=client.post('/api/profiles',headers=auth(),json={'name':'Serial test','asset_id':asset['id']}).json()
    job=client.post('/api/deployments',headers=auth(),json={'machine_id':machine['id'],'profile_id':profile['id'],'wizard_enabled':True,'confirmation':'EFFACER PC-SERIAL'}).json()
    url='/api/boot/connect'
    assert client.post(url,json={'code':job['boot_code'],'serial_number':'HP-OTHER-1234','macs':['00:11:22:33:44:55']}).status_code==403
    assert client.post(url,json={'code':job['boot_code'],'macs':['00:11:22:33:44:55']}).status_code==403
    response=client.post(url,json={'code':job['boot_code'],'serial_number':' hp-test-1234 ','macs':[]})
    assert response.status_code==200,response.text
    assert response.json()['plan']['serial_number']=='HP-TEST-1234'
    assert client.post('/api/machines',headers=auth(),json={'hostname':'PC-DUPLICATE','serial_number':'HP-TEST-1234'}).status_code==409


@pytest.mark.parametrize('case',['unique','duplicate','mixed'])
def test_old_mac_database_migrates_twice_without_losing_ids_reports_notes_or_foreign_keys(tmp_path,case):
    timestamp=datetime.now(timezone.utc).isoformat();artifact=tmp_path/'artifacts';artifact.mkdir()
    content=b'MSWIM\0\0\0old-identity-fixture';image=artifact/'old.wim';image.write_bytes(content);stat=image.stat()
    db=tmp_path/'deployment.sqlite3'
    with sqlite3.connect(db) as con:
        con.executescript('''
        CREATE TABLE machines(id TEXT PRIMARY KEY,hostname TEXT NOT NULL UNIQUE COLLATE NOCASE,mac TEXT NOT NULL UNIQUE,description TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE assets(id TEXT PRIMARY KEY,filename TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,sha256 TEXT NOT NULL,size INTEGER NOT NULL,mtime_ns INTEGER NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE profiles(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,asset_id TEXT NOT NULL REFERENCES assets(id),image_index INTEGER NOT NULL,locale TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE deployments(id TEXT PRIMARY KEY,machine_id TEXT NOT NULL REFERENCES machines(id),profile_id TEXT NOT NULL REFERENCES profiles(id),disk_number INTEGER NOT NULL,token_hash TEXT NOT NULL,status TEXT NOT NULL,progress INTEGER NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
        CREATE TABLE computer_reports(deployment_id TEXT PRIMARY KEY REFERENCES deployments(id),report_json TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE machine_notes(id INTEGER PRIMARY KEY AUTOINCREMENT,machine_id TEXT NOT NULL REFERENCES machines(id),text TEXT NOT NULL,author TEXT NOT NULL,created_at TEXT NOT NULL);
        ''')
        con.execute('INSERT INTO assets VALUES(?,?,?,?,?,?,?)',('image','old.wim','windows',hashlib.sha256(content).hexdigest(),stat.st_size,stat.st_mtime_ns,timestamp))
        con.execute('INSERT INTO profiles VALUES(?,?,?,?,?,?)',('profile','Old Windows','image',1,'fr-FR',timestamp))
        machines=['old-one','old-two'] if case=='duplicate' else ['old-one']
        for i,machine in enumerate(machines):
            con.execute('INSERT INTO machines VALUES(?,?,?,?,?)',(machine,'OLD-PC-'+str(i),'00:11:22:33:44:5'+str(i),'Old MAC history',timestamp))
            con.execute('INSERT INTO machine_notes(machine_id,text,author,created_at) VALUES(?,?,?,?)',(machine,'Keep technician note','Test',timestamp))
        reports={}
        for i,serial in enumerate(['HP-OLD-1234','HP-OTHER-5678'] if case=='mixed' else ['HP-OLD-1234']*len(machines)):
            machine=machines[min(i,len(machines)-1)];job='old-job-'+str(i)
            report=json.dumps({'hostname':'OLD-PC-0','inventory':{'Numero de serie':serial},'steps':[]})
            con.execute('INSERT INTO deployments VALUES(?,?,?,?,?,?,?,?,?)',(job,machine,'profile',0,digest('old-scoped-agent-token'),'failed',100,timestamp,timestamp))
            con.execute('INSERT INTO computer_reports VALUES(?,?,?)',(job,report,timestamp));reports[job]=report
    for _ in range(2):
        with TestClient(create_app(tmp_path,ADMIN,'https://atelier.test',internal_mode=True,auto_enroll=True)) as client:
            state=client.get('/api/state').json()
            first=next(m for m in state['machines'] if m['id']=='old-one')
            assert first['serial_number']==('HP-OLD-1234' if case=='unique' else None)
            assert first['mac']=='00:11:22:33:44:50'
            detail=client.get('/api/machines/old-one/details').json()
            assert detail['notes'][0]['text']=='Keep technician note'
            assert detail['total']==(2 if case=='mixed' else 1)
            assert 'legacy_mac_key' not in json.dumps(state)
    with TestClient(create_app(tmp_path,ADMIN,'https://atelier.test',internal_mode=True,auto_enroll=True)) as client:
        response=boot(client,'HP-OLD-1234',['00:11:22:33:44:99'])
        assert response.status_code==(409 if case=='duplicate' else 200),response.text
        if case=='unique':assert client.get('/api/state').json()['deployments'][0]['machine_id']=='old-one'
        if case=='mixed':assert len(client.get('/api/state').json()['machines'])==2
    with sqlite3.connect(db) as con:
        assert con.execute('PRAGMA foreign_key_check').fetchall()==[]
        assert dict(con.execute('SELECT deployment_id,report_json FROM computer_reports'))==reports


def test_failed_identity_migration_rolls_back_rename_and_can_be_retried(tmp_path):
    from app.identity import migrate_identity
    db=tmp_path/'atomic.sqlite3'
    with sqlite3.connect(db) as con:
        con.row_factory=sqlite3.Row
        con.executescript('CREATE TABLE machines(id TEXT PRIMARY KEY,hostname TEXT NOT NULL UNIQUE,mac TEXT NOT NULL UNIQUE,description TEXT NOT NULL,created_at TEXT NOT NULL);')
        con.execute("INSERT INTO machines VALUES('old','OLD-PC','00:11:22:33:44:55','Keep','2026-10-20')")
    with pytest.raises(sqlite3.OperationalError,match='computer_reports'):
        with sqlite3.connect(db) as con:
            con.row_factory=sqlite3.Row
            # Missing reports simulates an error after ALTER/UPDATE statements.
            migrate_identity(con)
    with sqlite3.connect(db) as con:
        con.row_factory=sqlite3.Row
        names={r['name'] for r in con.execute('PRAGMA table_info(machines)')}
        assert 'mac' in names and 'legacy_mac_key' not in names and 'serial_number' not in names
        assert con.execute('SELECT mac FROM machines').fetchone()[0]=='00:11:22:33:44:55'
        con.executescript('CREATE TABLE deployments(id TEXT,machine_id TEXT);CREATE TABLE computer_reports(deployment_id TEXT,report_json TEXT);')
        migrate_identity(con)
        assert con.execute('SELECT mac,serial_number FROM machines').fetchone()['serial_number'] is None


def test_booting_another_dock_cannot_reimage_windows_still_being_prepared(automatic):
    client,_,_,_=automatic
    session=boot(client,'HP-REBOOT-1234',['00:11:22:33:44:55']).json()
    route='/api/agent/'+session['id'];headers=auth(session['agent_token'])
    claim=client.post(route+'/claim',headers=headers).json()
    assert client.post(route+'/events',headers=headers,json={'status':'staged','progress':100,'message':'Image ready'}).status_code==200
    assert boot(client,'HP-REBOOT-1234',['00:11:22:33:44:66']).status_code==409
    assert client.post('/api/windows/'+session['id']+'/progress',headers=auth(claim['report_token']),json={'status':'completed','progress':100,'message':'Préparation complète'}).status_code==200
    again=boot(client,'HP-REBOOT-1234',['00:11:22:33:44:66'])
    assert again.status_code==200 and again.json()['id']!=session['id']
    state=client.get('/api/state').json()
    assert len(state['machines'])==1 and len(state['deployments'])==2
