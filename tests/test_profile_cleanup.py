"""Le catalogue de production reste simple et conserve les références historiques."""
import sqlite3
from app.main import create_app
from test_atelier3 import automatic


def test_startup_removes_single_language_and_renames_only_production_profiles(automatic):
    client,data,pro,home=automatic
    single=client.post('/api/profiles',json={'name':'Windows Famille unilingue','asset_id':pro['asset_id'],'edition':'Famille unilingue','image_index':3}).json()
    genuine=client.post('/api/profiles',json={'name':'Windows Pro | Test','asset_id':pro['asset_id'],'edition':'Pro'}).json()
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute('UPDATE profiles SET name=? WHERE id=?',('Windows 11 Pro FR - Test',pro['id']))
        con.execute('INSERT INTO windows_image_test_profiles VALUES (?,?)',(genuine['id'],'real-candidate'))
    create_app(data,internal_mode=True,auto_enroll=True,automatic_windows=True,client_software=True)
    state=client.get('/api/state').json()
    profiles={p['id']:p for p in state['profiles']}
    assert single['id'] not in profiles
    assert profiles[pro['id']]['name']=='Windows 11 Pro FR'
    assert profiles[genuine['id']]['name']=='Windows Pro | Test'
    assert profiles[genuine['id']]['image_test']
    result=client.post('/api/boot/discover',json={'serial_number':'TEST-6727','release':'ATELIER-4'}).json()
    assert single['id'] not in {p['id'] for p in result['catalog']['profiles']}
    assert result['plan']['profile_id']==pro['id']
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        assert con.execute('SELECT archived FROM profiles WHERE id=?',(single['id'],)).fetchone()==(1,)
    # La migration est répétable et conserve les index WIM d’origine.
    create_app(data,internal_mode=True)
    assert client.get('/api/state').json()['profiles']==state['profiles']


def test_storage_is_available_from_a_dedicated_authenticated_route(automatic):
    client,_,_,_=automatic
    result=client.get('/api/maintenance/storage')
    assert result.status_code==200
    assert result.json()['volumes']
