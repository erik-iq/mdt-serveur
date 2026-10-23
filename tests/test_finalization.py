"""Server-confirmed archiving and real removal of disposable client payloads."""
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

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')


def archive(entries=None):
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_DEFLATED) as z:
        for name,body in (entries or [('result.json','{"status":"completed"}'),('maintenance.json','{"status":"completed"}'),('software-logs/vlc.log','WinGet fixture'),('kb-KB5127648-console.log','Error: 0x80070228')]):z.writestr(name,body)
    return stream.getvalue()


def test_cleanup_proof_requires_current_report_all_files_integrity_and_scoped_credentials(system):
    client,data,job,headers=setup_reporter(system)
    route='/api/windows/'+job['id']
    report=client.post(route+'/report',headers=headers,json=snapshot()).json()
    proof={'report':report['sha256'],'xml':'a'*64,'csv':'b'*64,'diagnostics':'c'*64}
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==409
    bodies={'xml':b'<InventaireOrdinateur ordinateur="PC-LAB-01"/>','csv':b'Ordinateur;Categorie;Propriete;Valeur\nPC-LAB-01;CPU;Name;Test\n','diagnostics':archive()}
    for kind,body in bodies.items():
        response=client.post(route+'/inventory/'+kind,content=body,headers=headers)
        assert response.status_code==200,response.text
        assert response.json()['sha256']==hashlib.sha256(body).hexdigest()
        proof[kind]=response.json()['sha256']
    assert client.post(route+'/cleanup-ready',json=proof).status_code==401
    assert client.post(route+'/cleanup-ready',headers=auth(job['agent_token']),json=proof).status_code==401
    response=client.post(route+'/cleanup-ready',headers=headers,json=proof)
    assert response.status_code==200 and response.json()['hashes']==proof
    directory=client.get('/api/deployments/'+job['id']+'/inventory',headers=auth()).json()
    logs=next(f for f in directory['files'] if f['kind']=='diagnostics')
    assert logs['filename']=='Diagnostics-Deploiement.zip'
    assert client.get(logs['url']).status_code==401
    assert client.get(logs['url'],headers=auth()).content==bodies['diagnostics']
    assert 'Bearer' not in json.dumps(directory)
    path=data/'inventaires'/'PC-LAB-01'/job['id']/'Diagnostics-Deploiement.zip'
    path.write_bytes(b'altered server file')
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==409
    path.write_bytes(bodies['diagnostics'])
    assert client.post(route+'/cleanup-ready',headers=headers,json={**proof,'report':'0'*64}).status_code==409
    with sqlite3.connect(data/'deployment.sqlite3') as con:con.execute('UPDATE deployments SET report_expires=? WHERE id=?',('2000-01-01',job['id']))
    assert client.post(route+'/cleanup-ready',headers=headers,json=proof).status_code==401


@pytest.mark.parametrize('case',['credential_file','traversal','duplicates','invalid_json','missing_results','oversized_entry','symlink'])
def test_diagnostic_archive_rejects_credentials_unsafe_paths_and_invalid_or_unbounded_content(system,case):
    client,data,job,headers=setup_reporter(system)
    entries=[('result.json','{}'),('maintenance.json','{}')]
    if case=='credential_file':entries.append(('reporting.json','{"token":"must-not-be-stored"}'))
    if case=='traversal':entries.append(('../result.json','{}'))
    if case=='duplicates':entries.append(('result.json','{}'))
    if case=='invalid_json':entries[0]=('result.json','not json')
    if case=='missing_results':entries=[('progress.json','{}')]
    if case=='oversized_entry':entries.append(('software-logs/vlc.log','x'*(4*1024*1024+1)))
    if case=='symlink':
        entry=zipfile.ZipInfo('cleanup.log');entry.create_system=3;entry.external_attr=(0o120777<<16)
        entries.append((entry,'outside-target'))
    if case=='duplicates':
        with pytest.warns(UserWarning,match='Duplicate name'):payload=archive(entries)
    else:payload=archive(entries)
    reply=client.post('/api/windows/'+job['id']+'/inventory/diagnostics',headers=headers,content=payload)
    assert reply.status_code==422,reply.text
    assert not list((data/'inventaires').rglob('*.zip'))


def write_json(path,value):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,indent=2),encoding='utf-8')


@pytest.mark.skipif(not PWSH,reason='PowerShell required')
@pytest.mark.parametrize('case',['success','maintenance_worker','offline_retry','bad_archive_receipt','bad_final_proof','pending_report','stale_result','stale_report','active_installer','before_reboot','after_reboot','unsafe_link','unsafe_root','unsafe_previous','locked_file','failure_archived','hp_reports','hp_bad_receipt','hp_bad_proof','wu_unknown','wu_pending','wu_missing','wu_completed','wu_worker_busy','first_failure','kb_first_failure'])
def test_payload_removed_only_after_proof_and_native_process_exit_with_iq_preserved(tmp_path,case):
    program=tmp_path/'ProgramData';data=program/'AtelierPXE';data.mkdir(parents=True)
    iq=tmp_path/'IQ_';(iq/'Rapports').mkdir(parents=True);(iq/'Personnalisation').mkdir()
    (iq/'Personnalisation'/'Fond-Atelier.png').write_bytes(b'permanent wallpaper')
    identifier=str(uuid.uuid4())
    previous=program/('AtelierPXE-Previous-'+uuid.uuid4().hex);previous.mkdir();(previous/'old-state').write_text('référence image')
    write_json(data/'personalization.json',{'settings':{'winget_packages':[]},'deployment':{'id':identifier,'cleanup_after_reporting':True,'previous_payload_name':previous.name}})
    write_json(data/'reporting.json',{'id':identifier,'server_url':'https://atelier.test','token':'fixture-private-report-token','expires':'2099-01-01T00:00:00Z'})
    write_json(data/'result.json',{'status':'completed','deployment_id':identifier,'applications':[]})
    status='needs_attention' if case in ('failure_archived','wu_unknown','first_failure','kb_first_failure') else 'completed'
    write_json(data/'maintenance.json',{'status':status,'attempts':1,'timestamp':'2026-10-19T00:00:00Z','reboot_required':case in {'before_reboot','after_reboot'}})
    if case=='wu_unknown':
        record=json.loads((data/'maintenance.json').read_text())
        record['windows']={'source':'windows_update','status':'needs_attention','passes':[{'updates':[{'status':'installing'}]}]}
        write_json(data/'maintenance.json',record)
    if case in ('wu_pending','wu_missing','wu_completed','wu_worker_busy'):
        payload=json.loads((data/'personalization.json').read_text())
        payload['deployment']['automatic_windows_update']=True
        write_json(data/'personalization.json',payload)
        record=json.loads((data/'maintenance.json').read_text())
        record['windows']={'source':'windows_update','status':'completed'}
        write_json(data/'maintenance.json',record)
        if case!='wu_missing':
            write_json(data/'windows-update-result.json',{'source':'windows_update','status':'retry_pending' if case=='wu_pending' else 'completed'})
    if case in ('first_failure','kb_first_failure'):
        payload=json.loads((data/'personalization.json').read_text())
        payload['deployment']['hpia_first']=case=='first_failure'
        payload['deployment']['kb_first']=case=='kb_first_failure'
        write_json(data/'personalization.json',payload)
    write_json(data/'progress.json',{'status':status,'message':'Final state'})
    (data/'Inventory').mkdir();(data/'Inventory'/'Inventaire-Technique.xml').write_text('<InventaireOrdinateur ordinateur="PC-LAB"/>')
    (data/'Inventory'/'Inventaire-Technique.csv').write_text('Ordinateur;Catégorie;Propriété;Valeur\nPC-LAB;CPU;Name;Test\n')
    (data/'software-logs').mkdir();(data/'software-logs'/'vlc.log').write_text('fixture-private-report-token Downloaded VLC successfully')
    (data/'Unattend.generated.xml').write_text('<Password>private-setup-password</Password>')
    (data/'kb-KB5127648-console.log').write_text('Error: 0x80070228')
    hp_case=case in {'hp_reports','hp_bad_receipt','hp_bad_proof'}
    if hp_case:
        write_json(data/'personalization.json',{'settings':{'winget_packages':['hpia']},'deployment':{'id':identifier,'cleanup_after_reporting':True,'hp_repository':True,'previous_payload_name':previous.name}})
        reports=iq/'Rapports'/'HPImageAssistant'/identifier;reports.mkdir(parents=True)
        (reports/'native.log').write_text('HP detailed report fixture')
        write_json(data/'hpia-result.json',{'status':'completed','report_directory':str(reports)})
        for name in ['HP-Reports.ps1','HP-Repository.ps1']:shutil.copy(ROOT/'scripts'/name,data/name)
    report=json.dumps({'status':status,'hostname':'PC-LAB'},indent=2)
    (iq/'Rapports'/'Rapport-Deploiement.json').write_text(report)
    receipt={'status':'sent','deployment_id':identifier,'report_sha256':hashlib.sha256(report.encode()).hexdigest()}
    for name in ['result','maintenance']:receipt[name+'_sha256']=hashlib.sha256((data/(name+'.json')).read_bytes()).hexdigest()
    if case=='pending_report':receipt['status']='pending'
    write_json(iq/'Rapports'/'Transmission-Rapport.json',receipt)
    if case=='stale_result':(data/'result.json').write_text('{"status":"failed"}')
    if case=='stale_report':(iq/'Rapports'/'Rapport-Deploiement.json').write_text('{"status":"failed"}')
    outside=tmp_path/'outside';outside.mkdir();(outside/'keep').write_text('unrelated user file')
    if case=='unsafe_link':(data/'linked-directory').symlink_to(outside,target_is_directory=True)
    if case=='unsafe_root':
        hidden=program/'original';data.rename(hidden);data.symlink_to(hidden,target_is_directory=True)
    if case=='unsafe_previous':
        payload=json.loads((data/'personalization.json').read_text());payload['deployment']['previous_payload_name']='../outside';write_json(data/'personalization.json',payload)
    for name in ['Unattend.ps1','IQ-Paths.ps1','Finalization.ps1','Client-Software.ps1','HP-ImageAssistant.ps1','Maintenance.ps1']:shutil.copy(ROOT/'scripts'/name,data/name)
    (data/'Updates.ps1').write_text('function Disable-AtelierAutoLogon {}')
    wrapper=tmp_path/'run.ps1'
    wrapper.write_text(r'''
$ErrorActionPreference='Stop'
$env:ProgramData='PROGRAM'
$script:testMode='CASE'
function Get-Process {
 [CmdletBinding()]param($Id,$Name)
 if($script:testMode -eq 'active_installer'){[pscustomobject]@{ProcessName='HPImageAssistant';Id=123}}
}
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);[pscustomobject]@{LastBootUpTime=[datetime]'2026-10-20T00:00:00Z'}}
if($script:testMode -eq 'before_reboot'){function Get-CimInstance {param($ClassName,$OperationTimeoutSec);[pscustomobject]@{LastBootUpTime=[datetime]'2026-10-18T00:00:00Z'}}}
function Get-ScheduledTask {[CmdletBinding()]param($TaskName);[pscustomobject]@{TaskName=$TaskName;State='Ready'}}
function Unregister-ScheduledTask {[CmdletBinding()]param($TaskName,[switch]$Confirm);Add-Content 'ROOT/tasks' $TaskName}
function Invoke-RestMethod {
 param($Uri,$Method,$Headers,$ContentType,$InFile,$Body,$TimeoutSec)
 if($script:testMode -eq 'offline_retry'){throw 'Server offline'}
 if($Uri.EndsWith('/inventory/diagnostics')){
  [IO.File]::Copy($InFile,'ROOT/sent.zip',$true)
  $hash=(Get-FileHash $InFile -Algorithm SHA256).Hash.ToLowerInvariant()
  if($script:testMode -eq 'bad_archive_receipt'){$hash='0'*64}
  return @{accepted=$true;deployment_id='ID';sha256=$hash}
 }
 if($Uri.EndsWith('/inventory/hp_reports')){
  [IO.File]::Copy($InFile,'ROOT/hp-sent.zip',$true)
  $hash=(Get-FileHash $InFile -Algorithm SHA256).Hash.ToLowerInvariant()
  if($script:testMode -eq 'hp_bad_receipt'){$hash='0'*64}
  return @{accepted=$true;deployment_id='ID';sha256=$hash}
 }
 if($Uri.EndsWith('/cleanup-ready')){
  $proof=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
  if($script:testMode -eq 'bad_final_proof'){$proof.csv='0'*64}
  if($script:testMode -eq 'hp_bad_proof'){$proof.hp_reports='0'*64}
  if($script:testMode -eq 'hp_reports' -and (-not $proof.hp_reports -or $proof.hp_reports -ne (Get-FileHash 'ROOT/hp-sent.zip' -Algorithm SHA256).Hash.ToLowerInvariant())){throw 'HP proof missing'}
  return @{accepted=$true;cleanup_allowed=$true;deployment_id='ID';hashes=$proof}
 }
 return @{accepted=$true}
}
. 'DATA/Unattend.ps1'
. 'DATA/IQ-Paths.ps1'
. 'DATA/Finalization.ps1'
$held=$null
if($script:testMode -eq 'wu_worker_busy'){
 Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class WuaMutexFixture {
 static ManualResetEvent ready=new ManualResetEvent(false);
 static ManualResetEvent stop=new ManualResetEvent(false);
 static Thread worker;
 public static void Start() {
  worker=new Thread(() => {using(var mutex=new Mutex(false,"Global\\AtelierPXE-WindowsUpdateFirst")) {
   mutex.WaitOne();ready.Set();stop.WaitOne();mutex.ReleaseMutex();
  }});
  worker.Start();if(!ready.WaitOne(5000))throw new Exception("Mutex fixture timeout");
 }
 public static void Stop(){stop.Set();worker.Join();}
}
'@
 [WuaMutexFixture]::Start()
}
if($script:testMode -eq 'locked_file'){$held=[IO.File]::Open('DATA/result.json',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
if($script:testMode -eq 'maintenance_worker'){
 & 'DATA/Maintenance.ps1' -DataPath 'DATA' -ToolsPath 'IQ'
 $ok=-not (Test-Path 'DATA')
} else {
 $ok=Complete-AtelierLocalCleanup -DataPath 'DATA' -ToolsPath 'IQ'
 if($script:testMode -eq 'offline_retry'){
  if($ok -or -not (Test-Path 'DATA/reporting.json')){throw 'Offline payload was removed'}
  $script:testMode='success'
  $ok=Complete-AtelierLocalCleanup -DataPath 'DATA' -ToolsPath 'IQ'
 }
}
if($held){$held.Dispose()}
if($script:testMode -eq 'wu_worker_busy'){[WuaMutexFixture]::Stop()}
@{removed=$ok}|ConvertTo-Json|Set-Content 'ROOT/result.json'
'''.replace('PROGRAM',str(program)).replace('CASE',case).replace('DATA',str(data)).replace('ROOT',str(tmp_path)).replace("'IQ'","'"+str(iq)+"'").replace("'ID'","'"+identifier+"'"),encoding='utf-8-sig')
    run=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stderr+run.stdout
    removed=json.loads((tmp_path/'result.json').read_text(encoding='utf-8-sig'))['removed']
    expected=case in {'success','maintenance_worker','offline_retry','after_reboot','failure_archived','hp_reports','wu_completed'}
    assert removed==expected,(run.stdout,(data/'cleanup.log').read_text() if (data/'cleanup.log').exists() else '')
    assert data.exists()!=expected
    assert (outside/'keep').read_text()=='unrelated user file'
    assert (iq/'Personnalisation'/'Fond-Atelier.png').read_bytes()==b'permanent wallpaper'
    if expected:
        if hp_case:assert (tmp_path/'hp-sent.zip').exists()
        assert not previous.exists()
        assert set((tmp_path/'tasks').read_text().splitlines())=={'AtelierPXE-Preparation','AtelierPXE-WindowsUpdateFirst','AtelierPXE-Tools','AtelierPXE-Maintenance'}
        with zipfile.ZipFile(tmp_path/'sent.zip') as z:
            assert 'Unattend.generated.xml' not in z.namelist() and 'reporting.json' not in z.namelist()
            assert b'fixture-private-report-token' not in b''.join(z.read(n) for n in z.namelist())
            assert 'software-logs/vlc.log' in z.namelist()
            assert 'kb-KB5127648-console.log' in z.namelist()
        launcher=(iq/'Rapports'/'Generer-Rapport.ps1').read_text()
        assert '?deployment='+identifier+'&view=report' in launcher and 'ProgramData' not in launcher
    elif case in ('first_failure','kb_first_failure'):
        assert (tmp_path/'tasks').read_text().splitlines()==['AtelierPXE-Maintenance']
        assert (tmp_path/'sent.zip').exists()
        assert (data/'reporting.json').exists()
    else:
        assert not (tmp_path/'tasks').exists()
