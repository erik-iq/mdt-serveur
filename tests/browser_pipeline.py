"""Suivi réel dans le navigateur : étapes, horloge, états HP séparés et petit écran."""
from datetime import datetime,timezone,timedelta
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from urllib.request import Request,urlopen

from playwright.sync_api import expect,sync_playwright

ROOT=Path(__file__).resolve().parents[1]


def run():
    with tempfile.TemporaryDirectory(prefix='pipeline-browser-') as folder:
        data=Path(folder);(data/'artifacts').mkdir();(data/'artifacts/lab.wim').write_bytes(b'MSWIM\0\0\0fixture')
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        origin=f'http://127.0.0.1:{port}'
        env={**os.environ,'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':'fixture-browser-administrator',
             'MDT_BASE_URL':origin,'MDT_INTERNAL_MODE':'1','MDT_AUTO_ENROLL':'1','MDT_CLIENT_SOFTWARE':'1'}
        process=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:create_app','--factory','--host','127.0.0.1','--port',str(port)],
                                 cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        def api(path,body=None,token=None):
            headers={'Content-Type':'application/json'}
            if token:headers['Authorization']='Bearer '+token
            with urlopen(Request(origin+'/api'+path,headers=headers,data=json.dumps(body).encode() if body is not None else None),timeout=10) as response:return json.load(response)
        try:
            for _ in range(100):
                try:
                    with urlopen(origin+'/health',timeout=1):break
                except OSError:time.sleep(.1)
            image=api('/assets',{'filename':'lab.wim','kind':'windows'})
            profile=api('/profiles',{'name':'Windows 11 Pro FR','asset_id':image['id'],'edition':'Pro'})
            session=api('/boot/discover',{'serial_number':'PIPELINE-8736','release':'ATELIER-4'})
            token=session['agent_token'];identifier=session['id'];route='/agent/'+identifier
            api(route+'/configure',{'profile_id':profile['id'],'hostname':'HP-8736','settings':dict(profile['settings'],winget_packages=['hpia'])},token)
            reporter=api(route+'/claim',{},token)['report_token']
            api(route+'/events',{'status':'running','progress':20,'message':'Application de l’image'},token)
            api(route+'/events',{'status':'staged','progress':100,'message':'Image appliquée'},token)
            progress='/windows/'+identifier+'/progress'
            hp={'status':'running','progress':10,'message':'Analyse HP <fixture>','stage':'hpia','stage_status':'running'}
            api(progress,hp,reporter)
            started=(datetime.now(timezone.utc)-timedelta(minutes=3)).isoformat()
            with sqlite3.connect(data/'deployment.sqlite3') as con:
                con.execute('UPDATE deployment_phases SET started_at=?,updated_at=? WHERE deployment_id=?',(started,started,identifier))
                con.execute('UPDATE deployments SET windows_updated_at=? WHERE id=?',(started,identifier))
            api('/windows/'+identifier+'/hp-repository',{'platform':'8736','os':'win11','os_version':'26H2','required_softpaqs':['SP12345']},reporter)
            snapshot_id=str(uuid.uuid4());archive=data/'hp-repository/snapshots'/(snapshot_id+'.zip')
            with zipfile.ZipFile(archive,'w') as z:
                z.writestr('sp12345.exe',b'Fixture only');z.writestr('sp12345.cva','[Général]\nVersion=1.2\n')
            with sqlite3.connect(data/'deployment.sqlite3') as con:
                con.execute('INSERT INTO hp_repository_snapshots VALUES (?,?,?,?,?,?,?,?)',
                            (snapshot_id,'8736','win11','26H2','a'*64,archive.stat().st_size,'["SP12345"]',datetime.now(timezone.utc).isoformat()))
                con.execute("UPDATE hp_repository_jobs SET status='failed',message='CMSL : version non reconnue' WHERE platform='8736'")
            with sync_playwright() as p:
                browser=p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
                page=browser.new_page(viewport={'width':1440,'height':1050});errors=[]
                page.on('pageerror',lambda error:errors.append(str(error)))
                page.goto(origin);expect(page.locator('#connection')).to_have_text('Console connectée')
                row=page.locator('#deployments tr[data-job]')
                expect(row).to_contain_text('Préparation Windows en cours')
                expect(row.locator('.progress-cell')).to_contain_text('Windows : 10 %')
                expect(row.locator('.phase-clock')).to_contain_text('3 min')
                expect(row.locator('.phase-stale')).to_contain_text('Dernier signal reçu')
                expect(page.locator('#hp-repository-jobs')).to_contain_text('Cache disponible')
                expect(page.locator('#hp-repository-jobs')).to_contain_text('Actualisation échouée')
                expect(page.locator('#metric-active')).to_have_text('1')
                page.locator('#deployment-filter').select_option('active');expect(row).to_have_count(1)
                row.get_by_role('button',name='Suivre les étapes').click()
                expect(page.locator('#pipeline-dialog')).to_be_visible()
                expect(page.locator('.phase-card')).to_have_count(6)
                expect(page.locator('.phase-card.running')).to_contain_text('HPIA')
                expect(page.locator('.phase-card.running .phase-clock')).to_have_attribute('data-phase-clock',started)
                page.evaluate('async()=>{await refresh();await refresh();}')
                expect(page.locator('.phase-card.running .phase-clock')).to_have_attribute('data-phase-clock',started)
                assert page.locator('#pipeline-stages fixture').count()==0
                page.screenshot(path='/tmp/atelier-pipeline-desktop.png',full_page=True)
                api(progress,{**hp,'stage_status':'completed','message':'Pilotes installés'},reporter)
                api(progress,{**hp,'progress':45,'stage':'software','stage_status':'skipped','message':'Aucun logiciel demandé'},reporter)
                api(progress,{**hp,'progress':95,'stage':'restart','stage_status':'reboot_pending','message':'Redémarrage demandé'},reporter)
                page.evaluate('refresh()')
                expect(page.locator('.phase-card.completed')).to_have_count(2)
                expect(page.locator('.phase-card.reboot_pending')).to_contain_text('Redémarrage attendu')
                api(progress,{**hp,'progress':95,'stage':'restart','stage_status':'completed','message':'Démarrage confirmé'},reporter)
                api('/windows/'+identifier+'/report',{'hostname':'HP-8736','status':'completed','generated_at':datetime.now(timezone.utc).isoformat(),
                    'inventory':{'Modèle':'EliteBook 8736','Source des pilotes HP':'Serveurs HP (Internet)'},'steps':[],'warnings':[]},reporter)
                page.evaluate('refresh()')
                expect(page.locator('.phase-card.unknown')).to_contain_text('Dossier IQ')
                expect(page.locator('.phase-card.completed')).to_have_count(4)
                clock=page.locator('.phase-card').filter(has=page.get_by_role('heading',name='HPIA',exact=True)).locator('.phase-clock')
                frozen=clock.inner_text();page.wait_for_timeout(1200);assert clock.inner_text()==frozen
                page.evaluate("()=>{const e=document.getElementById('site-theme');e.value='dark';e.dispatchEvent(new Event('change'));}")
                page.set_viewport_size({'width':390,'height':844})
                assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
                assert page.locator('#pipeline-dialog').evaluate('(e)=>e.scrollWidth<=e.clientWidth+1')
                page.screenshot(path='/tmp/atelier-pipeline-mobile.png',full_page=True)
                page.locator('[data-close="pipeline-dialog"]').click()
                page.locator('#deployment-filter').select_option('all')
                expect(row).to_contain_text('Préparation réussie')
                expect(row).to_contain_text('Source HPIA déclarée : Téléchargement direct chez HP')
                expect(page.locator('#metric-active')).to_have_text('0')
                page.get_by_role('button',name='HPIA et pilotes',exact=True).click()
                card=page.locator('#hp-maintenance-models')
                expect(card).to_contain_text('Cache disponible');expect(card).to_contain_text('Actualisation échouée')
                expect(card).to_contain_text('Sources déclarées dans les bilans reçus')
                expect(card).to_contain_text('Téléchargement direct chez HP')
                assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
                assert not errors,errors
                browser.close()
            print('Pipeline browser passed: étapes, horloge stable, fin confirmée, source HP déclarée, cache et actualisation séparés, mobile sombre.')
        finally:process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
