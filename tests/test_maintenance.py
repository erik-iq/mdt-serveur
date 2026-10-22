"""Admin dashboards expose maintenance metadata, never worker keys or private mounts."""
import json
from pathlib import Path
import zipfile

import pytest

from test_api import auth, system
from test_hp_repository import hp_client, request_body, worker, write_snapshot
from app import maintenance

RUN = '20261021-103851-f52d8739'


def seed_report(data, asset_id='fixture-image'):
    root=data/'maintenance-overview';(root/'runs').mkdir(parents=True,exist_ok=True)
    report={'schema':2,'layout':'home_pro_fast_v1','scope':'home_pro','run_id':RUN,'status':'ready_for_test',
        'source_asset_id':asset_id,'source_path':'D:\\Images\\Windows.wim',
        'candidate_path':'D:\\AtelierPXE\\data\\windows-servicing\\runs\\'+RUN+'\\candidate.wim',
        'started_at':'2026-10-21T10:00:00Z','updated_at':'2026-10-21T11:00:00Z',
        'active_stage':'ready_for_test','active_index':0,'worker-key':'PRIVATE-KEY-MUST-NOT-LEAK',
        'indexes':[{'source_index':6,'index':2,'name':'Windows Pro','edition':'Professional','architecture':'x64',
            'version':{'family':'11','release':'26H2','dotnet':'4.8.1','build':26300},
            'updates':[{'kind':'os','update_id':'old-id','kb':'KB5127648','target_build':'26300.9711',
                'title':'Fixture cumulative','exit_code':0,'files':[{'filename':'fixture.msu','size':1234,'sha256':'a'*64,'url':'PRIVATE-URL-MUST-NOT-LEAK'}]}]}],
        'timings':[{'stage':'commit','index':2,'duration_seconds':65,'status':'completed'}]}
    (root/'runs'/(RUN+'.json')).write_text(json.dumps(report))
    (root/'status.json').write_text(json.dumps({'task_state':'Disabled','generated_at':'2026-10-21T11:00:00Z',
        'storage':[{'name':'backups','bytes':12345,'files':1,'complete':True}]}))
    return root


def test_windows_dashboard_is_read_only_authenticated_and_redacts_unpublished_fields(system, monkeypatch):
    client,data=system
    root=seed_report(data)
    private=data/'windows-servicing/runs'/RUN
    private.mkdir(parents=True);(private/'report.json').write_text('PRIVATE ORIGINAL REPORT')
    monkeypatch.setattr(maintenance,'select_plan',lambda *args:pytest.fail('GET must not contact Microsoft'))
    assert client.get('/api/maintenance/storage').status_code==401
    assert client.get('/api/maintenance/windows').status_code==401
    response=client.get('/api/maintenance/windows',headers=auth())
    assert response.status_code==200,response.text
    value=response.json();assert value['worker']['task_state']=='Disabled'
    assert value['reports'][0]['indexes'][0]['source_index']==6
    assert value['reports'][0]['indexes'][0]['index']==2
    storage=client.get('/api/maintenance/storage',headers=auth()).json()
    assert storage['volumes'][0]['free']>=0
    assert any(c['name']=='Sauvegardes WIM' for c in storage['categories'])
    assert 'storage' not in value
    assert 'PRIVATE' not in response.text
    url=value['reports'][0]['download_url']
    assert client.get(url).status_code==401
    download=client.get(url,headers=auth())
    assert download.status_code==200 and 'attachment' in download.headers['content-disposition']
    assert 'PRIVATE' not in download.text
    assert (private/'report.json').read_text()=='PRIVATE ORIGINAL REPORT'
    assert client.post('/api/maintenance/windows/prepare',headers=auth()).status_code==404


def test_catalog_button_checks_metadata_only_and_reports_new_kbs(system, monkeypatch):
    client,data=system;root=seed_report(data);calls=[]
    def select(*args,**kwargs):
        calls.append(args)
        return {'groups':[{'kind':'os','id':'new-id','kb':'KB5128000','title':'New fixture cumulative','target_build':'26300.9999','published':'2026-10-21'}]}
    monkeypatch.setattr(maintenance,'select_plan',select)
    assert client.post('/api/maintenance/windows/check').status_code==401
    assert client.post('/api/maintenance/windows/check',headers=auth()).status_code==202
    value=client.get('/api/maintenance/windows',headers=auth()).json()['catalog_check']
    assert value['status']=='completed' and value['contexts'][0]['groups'][0]['new']
    assert calls==[('11','26H2','x64','4.8.1')]
    assert not (data/'windows-servicing/packages').exists()
    assert not (data/'windows-servicing/runs'/RUN/'candidate.wim').exists()
    # A restart cannot leave the button permanently disabled by an old running marker.
    (root/'catalog-check.json').write_text('{"status":"running","contexts":[]}')
    assert client.get('/api/maintenance/windows',headers=auth()).json()['catalog_check']['status']=='interrupted'


def test_catalog_errors_are_visible_and_allow_retry(system,monkeypatch):
    client,data=system;seed_report(data)
    def fail(*args,**kwargs): raise ValueError('Microsoft catalogue indisponible')
    monkeypatch.setattr(maintenance,'select_plan',fail)
    for _ in range(2):
        assert client.post('/api/maintenance/windows/check',headers=auth()).status_code==202
        value=client.get('/api/maintenance/windows',headers=auth()).json()['catalog_check']
        assert value['status']=='failed' and 'indisponible' in value['message']


def test_hp_dashboard_lists_models_packages_cva_and_missing_cache(system):
    client,data,job,headers=hp_client(system)
    assert client.post('/api/windows/'+job['id']+'/hp-repository',headers=headers,json=request_body()).status_code==200
    assert client.post('/api/windows/'+job['id']+'/report',headers=headers,json={'hostname':'PC-LAB-01','status':'completed',
        'generated_at':'2026-10-21T11:00:00Z','inventory':{'Modele':'HP EliteBook <fixture>'},'steps':[],'warnings':[]}).status_code==200
    wh,identity=worker(client,data)
    claimed=client.post('/api/hp-repository/worker/claim',headers=wh,json=identity).json()['job']
    path=write_snapshot(data,claimed['id'])
    with zipfile.ZipFile(path) as archive: entries={e.filename:archive.read(e) for e in archive.infolist()}
    entries['sp12345.cva']=b'[General]\nVersion=1.2.3\n[Software Title]\nUS=Fixture Intel driver\n'
    with zipfile.ZipFile(path,'w') as archive:
        for name,content in entries.items():archive.writestr(name,content)
    assert client.post('/api/hp-repository/worker/jobs/'+claimed['id']+'/finish',headers=wh,json={**identity,'success':True}).status_code==200
    assert client.get('/api/maintenance/hp').status_code==401
    result=client.get('/api/maintenance/hp',headers=auth())
    assert result.status_code==200,result.text
    model=result.json()['models'][0]
    assert model['names']==['HP EliteBook <fixture>'] and model['machine_count']==1
    assert model['packages'][0]['version']=='1.2.3'
    assert model['packages'][0]['title']=='Fixture Intel driver'
    assert model['packages'][0]['id']=='SP12345' and not model['missing']
    assert (data/'hp-repository/worker-key').read_text().strip() not in result.text
    path.unlink()
    model=client.get('/api/maintenance/hp?fresh=true',headers=auth()).json()['models'][0]
    assert model['issues'] and model['missing']==['SP12345']


def test_dashboard_refuses_links_outside_its_data_directory(system,tmp_path):
    client,data=system;root=seed_report(data)
    outside=tmp_path/'private.json';outside.write_text('{"secret":"SHOULD-NOT-LEAK"}')
    path=root/'runs'/(RUN+'.json');path.unlink();path.symlink_to(outside)
    response=client.get('/api/maintenance/windows/runs/'+RUN+'/report',headers=auth())
    assert response.status_code==409 and 'SHOULD-NOT-LEAK' not in response.text
