"""Automatic discovery still requires a local WinPE installation click; no disk operation is in this API."""
from concurrent.futures import ThreadPoolExecutor
import json
import sqlite3

from fastapi.testclient import TestClient
import pytest

from app.main import create_app
from test_api import ADMIN, auth, register
from test_reporting import setup_reporter, system


@pytest.fixture
def automatic(tmp_path):
    with TestClient(create_app(tmp_path, ADMIN, 'https://atelier.test', internal_mode=True,
                              automatic_windows=True, client_software=True, auto_enroll=True)) as client:
        image=register(client,tmp_path)
        profile=client.post('/api/profiles',json={'name':'Windows Pro','edition':'Pro','asset_id':image['id']}).json()
        home=client.post('/api/profiles',json={'name':'Windows Famille','edition':'Famille','image_index':2,'asset_id':image['id']}).json()
        yield client,tmp_path,profile,home


def discover(client,mac='00:11:22:33:44:55'):
    return client.post('/api/boot/discover',json={'macs':[mac],'release':'ATELIER-4'})


def test_unknown_machine_enrolls_without_site_authorization_and_can_choose_home_and_disk(automatic):
    client,data,pro,home=automatic
    response=discover(client);assert response.status_code==200,response.text
    session=response.json();plan=session['plan']
    assert plan['status']=='queued' and plan['edition']=='Pro'
    assert plan['applications']==[] and plan['settings']['software_mode']=='winget'
    assert plan['settings']['central_inventory'] is True
    assert len(session['catalog']['profiles'])==2 and session['catalog']['applications']==[]
    selection={'profile_id':home['id'],'hostname':'PC-FAMILLE','settings':home['settings'],'disk_number':2}
    headers=auth(session['agent_token']);route='/api/agent/'+session['id']
    selected=client.post(route+'/configure',headers=headers,json=selection)
    assert selected.status_code==200,selected.text
    assert selected.json()['disk_number']==2 and selected.json()['edition']=='Famille'
    assert client.get('/api/state').json()['deployments'][0]['hostname']=='PC-FAMILLE'
    assert client.post(route+'/claim',headers=headers).status_code==200
    assert discover(client).status_code==409


def test_concurrent_boots_reuse_one_job_and_rotate_credentials(automatic):
    client,data,_,_=automatic
    with ThreadPoolExecutor(max_workers=2) as pool:
        sessions=list(pool.map(lambda _:discover(client).json(),range(2)))
    assert sessions[0]['id']==sessions[1]['id']
    state=client.get('/api/state').json()
    assert len(state['machines'])==1 and len(state['deployments'])==1
    statuses=[client.get('/api/agent/'+s['id']+'/plan',headers=auth(s['agent_token'])).status_code for s in sessions]
    assert sorted(statuses)==[200,401]


def test_prepared_windows_does_not_loop_back_into_reimage(automatic):
    client,data,_,_=automatic
    session=discover(client).json();headers=auth(session['agent_token']);route='/api/agent/'+session['id']
    claim=client.post(route+'/claim',headers=headers).json()
    client.post(route+'/events',headers=headers,json={'status':'staged','progress':100,'message':'Windows prepared'})
    assert discover(client).status_code==409
    client.post('/api/windows/'+session['id']+'/progress',headers=auth(claim['report_token']),json={'status':'completed','progress':100,'message':'Windows ready'})
    assert discover(client).status_code==200


def test_invalid_macs_external_origin_and_no_image_do_not_enroll(automatic):
    client,data,_,_=automatic
    for mac in ['bogus','01:11:22:33:44:55','00:00:00:00:00:00']:
        assert discover(client,mac).status_code==422
    assert client.post('/api/boot/discover',headers={'Origin':'https://evil.test'},json={'macs':['00:11:22:33:44:55']}).status_code==403
    assert client.get('/api/state').json()['machines']==[]


def test_stale_software_files_are_not_needed_in_winpe(automatic):
    client,data,pro,_=automatic
    asset=register(client,data,'anydesk-old.exe','application')
    app=client.post('/api/applications',json={'name':'AnyDesk','asset_id':asset['id']}).json()
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        settings={**pro['settings'],'software_mode':'catalogue','application_ids':[app['id']]}
        con.execute('UPDATE profiles SET settings_json=? WHERE id=?',(json.dumps(settings),pro['id']))
    (data/'artifacts'/'anydesk-old.exe').unlink()
    response=discover(client)
    assert response.status_code==200,response.text
    assert response.json()['plan']['applications']==[]


def test_inventory_upload_scoped_validated_idempotent_and_downloadable(system):
    client,data,job,headers=setup_reporter(system)
    base='/api/windows/'+job['id']+'/inventory/'
    xml=b'<?xml version="1.0"?><InventaireOrdinateur ordinateur="PC-LAB-01"><Proprietes>'+b' '*150000+b'</Proprietes></InventaireOrdinateur>'
    csv='"Ordinateur";"Categorie";"Propriete";"Valeur"\n"PC-LAB-01";"CPU";"Nom";"Test CPU"\n'.encode()
    assert client.post(base+'xml',content=xml).status_code==401
    assert client.post(base+'xml',content=xml,headers=auth(job['agent_token'])).status_code==401
    for _ in range(2):
        for kind,body in [('xml',xml),('csv',csv)]:
            response=client.post(base+kind,headers=headers,content=body)
            assert response.status_code==200,response.text
    folder=data/'inventaires'/'PC-LAB-01'/job['id']
    assert (folder/'Inventaire-Technique.xml').read_bytes()==xml
    assert (folder/'Inventaire-Technique.csv').read_bytes()==csv
    route='/api/deployments/'+job['id']+'/inventory'
    assert client.get(route).status_code==401
    view=client.get(route,headers=auth()).json()
    assert len(view['files'])==2 and view['server_directory']==str(folder)
    assert client.get(route+'/csv',headers=auth()).content==csv
    assert client.get('/api/state',headers=auth()).json()['deployments'][0]['has_inventory']==1
    assert headers['Authorization'] not in json.dumps(view)


def test_inventory_rejects_identity_mismatch_dtd_invalid_csv_and_expired_token(system):
    client,data,job,headers=setup_reporter(system)
    base='/api/windows/'+job['id']+'/inventory/'
    for kind,body in [('xml',b'<InventaireOrdinateur ordinateur="OTHER-PC"/>'),
                      ('xml',b'<!DOCTYPE x [<!ENTITY a "test">]><InventaireOrdinateur ordinateur="PC-LAB-01"/>'),
                      ('csv',b'not;an;inventory')]:
        assert client.post(base+kind,headers=headers,content=body).status_code==422
    assert not list((data/'inventaires').rglob('*.xml'))
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute("UPDATE deployments SET report_expires='2000-01-01' WHERE id=?",(job['id'],))
    assert client.post(base+'xml',headers=headers,content=b'<InventaireOrdinateur ordinateur="PC-LAB-01"/>').status_code==401


def test_new_deployment_no_longer_depends_on_legacy_hp_zip(automatic):
    client,data,_,_=automatic
    asset=register(client,data,'hp-tool.zip','application')
    tool=client.post('/api/applications',json={'name':'HP Image Assistant','asset_id':asset['id'],'entry_point':'HPImageAssistant.exe','install_mode':'portable','manufacturer':'hp'}).json()
    other=register(client,data,'other.exe','application')
    session=discover(client).json()
    assert session['plan']['applications']==[] and session['plan']['tools']==[]
    route='/api/agent/'+session['id']
    reporter=client.post(route+'/claim',headers=auth(session['agent_token'])).json()['report_token']
    base='/api/windows/'+session['id']+'/tools/'
    assert client.get(base+asset['id'],headers=auth(reporter)).status_code==403
    assert client.get(base+asset['id'],headers=auth(session['agent_token'])).status_code==401
    assert client.get(base+other['id'],headers=auth(reporter)).status_code==403


def test_old_winpe_is_rejected_before_automatic_enrollment(automatic):
    client,_,_,_=automatic
    response=client.post('/api/boot/discover',json={'macs':['00:11:22:33:44:55']})
    assert response.status_code==409 and 'ATELIER-4' in response.json()['detail']
    assert client.get('/api/state').json()['machines']==[]
