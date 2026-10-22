"""Archive detailed HP evidence without credentials; require proof before cleanup."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import uuid
import zipfile

import pytest

from test_api import auth,system
from test_reporting import setup_reporter,snapshot
from test_finalization import archive as diagnostics_archive

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


def hp_archive(extra=None):
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('hpia-result.json','{"status":"needs_attention"}')
        z.writestr('Installation/SoftPaqReport.csv','SoftPaqID,AutoInstallable\nSP12345,FALSE\n')
        if extra:z.writestr(*extra)
    return stream.getvalue()


@pytest.mark.parametrize('revision',['IQ-4.9','IQ-5.0'])
def test_hp_report_archive_is_private_and_required_for_new_hp_cleanup(system,revision):
    client,data,job,headers=setup_reporter(system);route='/api/windows/'+job['id']
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute('UPDATE deployments SET selection_json=? WHERE id=?',(json.dumps({'hostname':'PC-LAB-01','settings':{'winget_packages':['hpia']}}),job['id']))
    body=snapshot();body['inventory']['Revision preparation']=revision
    report=client.post(route+'/report',headers=headers,json=body).json()
    proof={'report':report['sha256']}
    for kind,payload in {'xml':b'<InventaireOrdinateur ordinateur="PC-LAB-01"/>','csv':b'Ordinateur;Categorie;Propriete;Valeur\nPC-LAB-01;CPU;Name;Fixture\n','diagnostics':diagnostics_archive()}.items():
        reply=client.post(route+'/inventory/'+kind,headers=headers,content=payload)
        assert reply.status_code==200,reply.text
        proof[kind]=reply.json()['sha256']
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==409
    archive=hp_archive(('Installation/debug.log','SoftPaq fixture'))
    assert client.post(route+'/inventory/hp_reports',content=archive).status_code==401
    sent=client.post(route+'/inventory/hp_reports',headers=headers,content=archive)
    assert sent.status_code==200,sent.text
    proof['hp_reports']=sent.json()['sha256']
    assert proof['hp_reports']==hashlib.sha256(archive).hexdigest()
    folder=client.get('/api/deployments/'+job['id']+'/inventory',headers=auth()).json()
    entry=next(f for f in folder['files'] if f['kind']=='hp_reports')
    assert entry['filename']=='Rapports-HP.zip'
    assert client.get(entry['url']).status_code==401
    assert client.get(entry['url'],headers=auth()).content==archive
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==200
    stored=Path(folder['server_directory'])/'Rapports-HP.zip';stored.write_bytes(b'Changed server data')
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==409


@pytest.mark.parametrize('case',['private','traversal','script','duplicate','entity','invalid_result','symlink'])
def test_hp_archive_rejects_private_files_unsafe_paths_and_entities(system,case):
    client,_,job,headers=setup_reporter(system)
    entry={
        'private':('Installation/reporting.json','{"token":"private"}'),
        'traversal':('../report.xml','<Report/>'),
        'script':('Installation/install.ps1','bad'),
        'duplicate':('HPIA-RESULT.JSON','{}'),
        'entity':('Installation/result.xml','<!DOCTYPE a [<!ENTITY x SYSTEM "file:///private">]><a>&x;</a>'),
        'invalid_result':None,
    }.get(case)
    if case=='symlink':
        name=zipfile.ZipInfo('Installation/log.txt');name.create_system=3;name.external_attr=0o120777<<16;entry=(name,'outside')
    payload=hp_archive(entry)
    if case=='invalid_result':
        stream=io.BytesIO()
        with zipfile.ZipFile(stream,'w') as z:z.writestr('hpia-result.json','not-json')
        payload=stream.getvalue()
    response=client.post('/api/windows/'+job['id']+'/inventory/hp_reports',headers=headers,content=payload)
    assert response.status_code==422,response.text


def test_partial_native_reports_are_preserved_as_evidence_without_being_parsed(system):
    client,_,job,headers=setup_reporter(system)
    response=client.post('/api/windows/'+job['id']+'/inventory/hp_reports',headers=headers,content=hp_archive(('Installation/partial.json','{"HPIA":')))
    assert response.status_code==200,response.text


@pytest.mark.parametrize('canonical',[False,True])
def test_installation_page_round_trip_is_an_authenticated_attachment_and_visible_on_computer(system,canonical):
    client,data,job,headers=setup_reporter(system)
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w') as z:
        z.writestr('hpia-result.json','{"status":"completed","exit_code":3010}')
        z.writestr('Passage-01/Installation/HP Model.html','<html>Pre-install analysis</html>')
        z.writestr('Passage-01/Installation/Readme (20261021 152514).html','<html>First installation</html>')
        z.writestr('Passage-02/Installation/Readme (20261021 153000).html','<html>Second installation</html>')
        if canonical:z.writestr('Rapport-Installation-HP.html','<html>Canonical installation</html>')
    payload=stream.getvalue()
    expected=b'<html>Canonical installation</html>' if canonical else b'<html>Second installation</html>'
    sent=client.post('/api/windows/'+job['id']+'/inventory/hp_reports',headers=headers,content=payload)
    assert sent.status_code==200,sent.text
    assert sent.json()['hp_summary']['sha256']==hashlib.sha256(expected).hexdigest()
    folder=client.get('/api/deployments/'+job['id']+'/inventory',headers=auth()).json()
    summary=next(f for f in folder['files'] if f['kind']=='hp_summary')
    assert summary['filename']=='Rapport-Installation-HP.html'
    assert (Path(folder['server_directory'])/summary['filename']).read_bytes()==expected
    assert client.get(summary['url']).status_code==401
    response=client.get(summary['url'],headers=auth())
    assert response.content==expected and response.headers['content-type']=='application/octet-stream'
    assert response.headers['content-disposition'].startswith('attachment;')
    assert response.headers['x-content-type-options']=='nosniff'
    state=client.get('/api/state',headers=auth()).json()
    deployment=next(d for d in state['deployments'] if d['id']==job['id'])
    assert deployment['has_hp_summary']
    details=client.get('/api/machines/'+deployment['machine_id']+'/details',headers=auth()).json()
    assert details['deployments'][0]['has_hp_summary']
    assert client.post('/api/windows/'+job['id']+'/inventory/hp_summary',headers=headers,content=expected).status_code==404
    replaced=client.post('/api/windows/'+job['id']+'/inventory/hp_reports',headers=headers,content=hp_archive())
    assert replaced.status_code==200 and replaced.json()['hp_summary'] is None
    assert client.get(summary['url'],headers=auth()).status_code==404
    assert not (Path(folder['server_directory'])/summary['filename']).exists()


def test_cleanup_waits_for_the_native_html_copy_as_well_as_the_archive(system):
    client,data,job,headers=setup_reporter(system);route='/api/windows/'+job['id']
    report=client.post(route+'/report',headers=headers,json=snapshot()).json()
    proof={'report':report['sha256']}
    bodies={'xml':b'<InventaireOrdinateur ordinateur="PC-LAB-01"/>','csv':b'Ordinateur;Categorie;Propriete;Valeur\nPC-LAB-01;CPU;Name;Fixture\n','diagnostics':diagnostics_archive(),
            'hp_reports':hp_archive(('Rapport-Installation-HP.html','<html>Installed HP drivers</html>'))}
    for kind,body in bodies.items():
        response=client.post(route+'/inventory/'+kind,headers=headers,content=body)
        assert response.status_code==200,response.text
        proof[kind]=response.json()['sha256']
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==200
    folder=client.get('/api/deployments/'+job['id']+'/inventory',headers=auth()).json()
    page=Path(folder['server_directory'])/'Rapport-Installation-HP.html'
    page.write_text('Modified report')
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==409
    assert client.get(route.replace('/windows/','/deployments/')+'/inventory/hp_summary',headers=auth()).status_code==409


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
@pytest.mark.parametrize('case',['success','bad_receipt','bad_summary_receipt','outside','symlink','not_run'])
def test_real_report_packaging_is_deterministic_redacts_tokens_and_validates_receipt(tmp_path,case):
    data=tmp_path/'data';data.mkdir();identifier=str(uuid.uuid4())
    iq=tmp_path/'IQ_';reports=iq/'Rapports'/'HPImageAssistant'/identifier
    (reports/'Installation').mkdir(parents=True)
    (reports/'Installation'/'native.log').write_text('HP détail private-fixture-report-token')
    (reports/'Installation'/'native.xml').write_text('<?xml version="1.0" encoding="utf-16"?><Report>Fixture</Report>',encoding='utf-16')
    (reports/'Installation'/'Readme (20261021 152514).html').write_text('<html>Native installation summary</html>')
    (reports/'Rapport-Installation-HP.html').write_text('<html>Canonical private-fixture-report-token</html>')
    (reports/'Installation'/'reporting.json').write_text('{"token":"must-not-be-in-zip"}')
    if case=='symlink':(reports/'linked').symlink_to(data,target_is_directory=True)
    if case!='not_run':(data/'hpia-result.json').write_text(json.dumps({'status':'completed','report_directory':str(tmp_path if case=='outside' else reports)}))
    shutil.copy(ROOT/'scripts'/'HP-Repository.ps1',data/'HP-Repository.ps1')
    script=r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$InFile,$TimeoutSec)
 if($Uri -ne 'https://atelier.test/api/windows/ID/inventory/hp_reports'){throw 'Wrong upload route'}
 Add-Content 'ROOT/calls' 'upload'
 Copy-Item -LiteralPath $InFile -Destination 'ROOT/sent.zip' -Force
 $hash=(Get-FileHash $InFile -Algorithm SHA256).Hash.ToLowerInvariant()
 $algorithm=[Security.Cryptography.SHA256]::Create()
 try{$summaryHash=([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes('<html>Canonical [REDACTED]</html>')))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
 @{accepted=$true;deployment_id='ID';sha256=$(if('CASE' -eq 'bad_receipt'){'0'*64}else{$hash});hp_summary=@{sha256=$(if('CASE' -eq 'bad_summary_receipt'){'0'*64}else{$summaryHash})}}
}
$config=@{id='ID';token='private-fixture-report-token';server_url='https://atelier.test'}
try {
 $first=Send-AtelierHpReports -DataPath 'DATA' -ToolsPath 'ROOT/IQ_' -Config $config
 $second=Send-AtelierHpReports -DataPath 'DATA' -ToolsPath 'ROOT/IQ_' -Config $config
 @{status='success';first=$first;second=$second}|ConvertTo-Json|Set-Content 'ROOT/out.json'
} catch {@{status='failed';message=$_.Exception.Message}|ConvertTo-Json|Set-Content 'ROOT/out.json'}
'''.replace('LIBRARY',str(ROOT/'scripts'/'HP-Reports.ps1')).replace('ROOT',str(tmp_path)).replace('DATA',str(data)).replace("'ID'","'"+identifier+"'").replace('/ID/','/'+identifier+'/').replace('CASE',case)
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    outcome=json.loads((tmp_path/'out.json').read_text(encoding='utf-8-sig'))
    if case in {'success','not_run'}:
        assert outcome['status']=='success' and outcome['first']==outcome['second'],outcome
        assert (tmp_path/'calls').read_text().splitlines()==['upload']
        with zipfile.ZipFile(tmp_path/'sent.zip') as z:
            assert 'hpia-result.json' in z.namelist()
            if case=='success':
                assert b'private-fixture-report-token' not in z.read('Installation/native.log')
                assert b'[REDACTED]' in z.read('Installation/native.log')
                assert 'Installation/reporting.json' not in z.namelist()
                assert b'encoding="utf-8"' in z.read('Installation/native.xml')
                assert 'Installation/Readme (20261021 152514).html' in z.namelist()
                assert z.read('Rapport-Installation-HP.html')==b'<html>Canonical [REDACTED]</html>'
    else:
        assert outcome['status']=='failed',outcome
        assert not (data/'hp-reports-sent.json').exists()


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
@pytest.mark.parametrize('confirmed',[False,True])
def test_final_report_archives_hp_before_receipt_even_while_manual_reboot_is_pending(tmp_path,confirmed):
    data=tmp_path/'data';data.mkdir();iq=tmp_path/'IQ_';identifier=str(uuid.uuid4())
    for name in ['Reporting.ps1','Client-Software.ps1','Inventory-Transfer.ps1','HP-Repository.ps1','HP-Reports.ps1']:
        shutil.copy(ROOT/'scripts'/name,data/name)
    payload={'settings':{'central_inventory':True,'software_mode':'winget','winget_packages':['hpia']},'deployment':{'id':identifier,'hp_repository':True,'cleanup_after_reporting':True}}
    (data/'personalization.json').write_text(json.dumps(payload))
    (data/'reporting.json').write_text(json.dumps({'id':identifier,'server_url':'https://atelier.test','token':'fixture-report-token-not-real','expires':'2099-01-01'}))
    (data/'result.json').write_text(json.dumps({'status':'completed','applications':[{'id':'hpia','status':'completed','name':'HP Image Assistant','tool':{'path':'verified fixture'}}]}))
    (data/'maintenance.json').write_text(json.dumps({'status':'needs_attention','reboot_required':True,'windows':{'status':'manual'},'store':{'status':'manual'}}))
    reports=iq/'Rapports'/'HPImageAssistant'/identifier;reports.mkdir(parents=True)
    (reports/'native.log').write_text('HP installation detailed fixture')
    for number in (1,2):
        passage=reports/f'Passage-{number:02}'/'Installation';passage.mkdir(parents=True)
        (passage/'native.log').write_text(f'HP pass {number}')
    (data/'hpia-result.json').write_text(json.dumps({'status':'completed','source':'depot_250','reboot_required':True,'report_directory':str(reports),'pass_number':2,'resumed_after_reboot':True,'history':[{'pass_number':1,'status':'reboot_pending','message':'BIOS applied; restart required','exit_code':3010,'timestamp':'2026-10-20T10:00:00Z','packages':[{'softpaq_id':'SP12345','name':'System BIOS','code':3010}]}]}))
    (iq/'Licence').mkdir();(iq/'Licence'/'Licence-Windows.json').write_text('{"état":"ACTIVE"}')
    (data/'Export-Inventaire.ps1').write_text(r'''param($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
Set-Content (Join-Path $OutputDirectory 'Inventaire-Technique.xml') '<InventaireOrdinateur ordinateur="PC-LAB-01"/>'
Set-Content (Join-Path $OutputDirectory 'Inventaire-Technique.csv') "Ordinateur;Catégorie;Propriété;Valeur`nPC-LAB-01;CPU;Name;Fixture"
[pscustomobject]@{SectionsIndisponibles=0}
''')
    script=r'''
$ErrorActionPreference='Stop'
$env:COMPUTERNAME='PC-LAB-01'
function Get-CimInstance {
 param($ClassName,$OperationTimeoutSec)
 [pscustomobject]@{Manufacturer='HP';Model='EliteBook';TotalPhysicalMemory=16GB;SerialNumber='TEST123456';SMBIOSBIOSVersion='1.2';Caption='Windows 11 Pro';Version='10.0.26200';BuildNumber='26200';OSArchitecture='64 bits';Name='Test CPU';NumberOfCores=4;NumberOfLogicalProcessors=8;Size=512GB;IPEnabled=$true;Description='Ethernet';MACAddress='00:11:22:33:44:55';IPAddress=@('192.168.99.10')}
}
function Get-ItemProperty {param($Path,$Name);[pscustomobject]@{HiberbootEnabled=0;EditionID='Professional'}}
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$InFile,$Body,$TimeoutSec)
 Add-Content 'ROOT/calls' $Uri
 if($Uri.EndsWith('/inventory/hp_reports')){
  Copy-Item -LiteralPath $InFile -Destination 'ROOT/hp-sent.zip'
  return @{accepted=CONFIRMED;deployment_id='ID';sha256=(Get-FileHash $InFile -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
 if($Uri.EndsWith('/report')){
  $hash=[Security.Cryptography.SHA256]::Create()
  try {$digest=([BitConverter]::ToString($hash.ComputeHash($Body))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
  return @{accepted=$true;deployment_id='ID';sha256=$digest}
 }
 return @{accepted=$true}
}
& 'SCRIPT' -DataPath 'DATA' -OutputDirectory 'ROOT/IQ_'
'''.replace('SCRIPT',str(ROOT/'scripts'/'New-DeploymentReport.ps1')).replace('DATA',str(data)).replace('ROOT',str(tmp_path)).replace("'ID'","'"+identifier+"'").replace('/ID/','/'+identifier+'/').replace('CONFIRMED','$true' if confirmed else '$false')
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    receipt=json.loads((iq/'Rapports'/'Transmission-Rapport.json').read_text(encoding='utf-8-sig'))
    assert receipt['status']==('sent' if confirmed else 'pending')
    calls=(tmp_path/'calls').read_text().splitlines()
    assert calls[0].endswith('/inventory/hp_reports')
    assert len(calls)==(4 if confirmed else 1),calls
    assert (data/'reporting.json').exists()
    report=json.loads((iq/'Rapports'/'Rapport-Deploiement.json').read_text(encoding='utf-8-sig'))
    assert report['inventory']['Revision preparation']=='IQ-4.9'
    assert report['inventory']['Source des pilotes HP']=='Dépôt local .250'
    assert any(step['name']=='HP passage 1 avant redémarrage' for step in report['steps'])
    assert any(step['name']=='Reprise HP après redémarrage' for step in report['steps'])
    assert 'HP passage 1 avant redémarrage'.encode('cp1252') in (iq/'Rapports'/'Rapport-Deploiement.pdf').read_bytes()
    with zipfile.ZipFile(tmp_path/'hp-sent.zip') as z:
        assert {'Passage-01/Installation/native.log','Passage-02/Installation/native.log'} <= set(z.namelist())
