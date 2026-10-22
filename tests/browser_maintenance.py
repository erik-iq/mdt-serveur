"""Real browser checks for both maintenance pages, downloads, escaping and mobile layout."""
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
sys.path.insert(0,str(ROOT))
from test_maintenance import seed_report, RUN


def run():
    with tempfile.TemporaryDirectory(prefix='maintenance-browser-') as folder:
        data=Path(folder);(data/'artifacts').mkdir();(data/'artifacts/lab.wim').write_bytes(b'MSWIM\0\0\0fixture')
        with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        origin=f'http://127.0.0.1:{port}'
        env={**os.environ,'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':'fixture-browser-admin-token-not-secret',
            'MDT_BASE_URL':origin,'MDT_INTERNAL_MODE':'1','MDT_AUTO_ENROLL':'1','MDT_CLIENT_SOFTWARE':'1'}
        process=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:create_app','--factory','--host','127.0.0.1','--port',str(port)],
            cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        def api(path,body=None,token=None):
            headers={'Content-Type':'application/json'}
            if token:headers['Authorization']='Bearer '+token
            with urlopen(Request(origin+'/api'+path,headers=headers,data=json.dumps(body).encode() if body is not None else None)) as response:return json.load(response)
        try:
            for _ in range(100):
                try:
                    with urlopen(origin+'/health',timeout=1):break
                except OSError:time.sleep(.1)
            image=api('/assets',{'filename':'lab.wim','kind':'windows'})
            profile=api('/profiles',{'name':'Windows atelier','asset_id':image['id'],'edition':'Pro'})
            session=api('/boot/discover',{'serial_number':'BROWSER-8323','release':'ATELIER-4'})
            settings=dict(profile['settings'],winget_packages=['hpia'])
            route='/agent/'+session['id'];token=session['agent_token']
            api(route+'/configure',{'profile_id':profile['id'],'hostname':'PC-8323','settings':settings},token)
            reporter=api(route+'/claim',{},token)['report_token']
            api(route+'/events',{'status':'staged','progress':100,'message':'Fixture staged'},token)
            api('/windows/'+session['id']+'/report',{'hostname':'PC-8323','status':'completed','generated_at':'2026-10-21T10:00:00Z',
                'inventory':{'Modele':'EliteBook <fixture>'},'steps':[],'warnings':[]},reporter)
            api('/windows/'+session['id']+'/hp-repository',{'platform':'83B2','os':'win11','os_version':'26H2','required_softpaqs':['SP12345']},reporter)
            snapshot_id=str(uuid.uuid4());archive=data/'hp-repository/snapshots'/(snapshot_id+'.zip')
            with zipfile.ZipFile(archive,'w') as z:
                z.writestr('sp12345.exe',b'Fixture only')
                z.writestr('sp12345.cva','[General]\nVersion=1.2.3\n[Software Title]\nUS=Intel <fixture> driver\n')
            with sqlite3.connect(data/'deployment.sqlite3') as con:
                con.execute('INSERT INTO hp_repository_snapshots VALUES (?,?,?,?,?,?,?,?)',
                    (snapshot_id,'83B2','win11','26H2','a'*64,archive.stat().st_size,'["SP12345"]','2026-10-21T10:00:00Z'))
            public=seed_report(data,image['id'])
            with sync_playwright() as p:
                browser=p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
                page=browser.new_page(viewport={'width':1440,'height':1050});errors=[]
                page.on('pageerror',lambda e:errors.append(str(e)))
                page.goto(origin);expect(page.locator('#connection')).to_have_text('Console connectee')
                page.get_by_role('button',name='HPIA et pilotes',exact=True).click()
                expect(page.locator('#hp-maintenance-models')).to_contain_text('EliteBook <fixture>')
                page.locator('#hp-maintenance-models summary').click()
                expect(page.locator('#hp-maintenance-models')).to_contain_text('1.2.3')
                expect(page.locator('#hp-maintenance-models')).to_contain_text('Intel <fixture> driver')
                assert page.locator('#hp-maintenance-models fixture').count()==0
                page.locator('#hp-maintenance-search').fill('SP12345')
                expect(page.locator('[data-hp-search]')).to_be_visible()
                page.locator('#hp-maintenance-search').fill('no match')
                expect(page.locator('[data-hp-search]')).to_be_hidden()
                page.locator('#hp-maintenance-search').fill('')
                page.screenshot(path='/tmp/atelier-maintenance-hp.png',full_page=True)
                page.get_by_role('button',name='Images et correctifs',exact=True).click()
                expect(page.locator('#windows-maintenance-runs')).to_contain_text('Candidate a tester')
                page.locator('#windows-maintenance-runs summary').click()
                expect(page.locator('#windows-maintenance-runs')).to_contain_text('KB5127648')
                expect(page.locator('#windows-maintenance-runs')).to_contain_text('1 min 5 s')
                with page.expect_download() as download:
                    page.get_by_role('button',name='Telecharger le rapport JSON',exact=True).click()
                assert json.loads(Path(download.value.path()).read_text())['run_id']==RUN
                assert 'PRIVATE' not in Path(download.value.path()).read_text()
                def catalog(route):
                    (public/'catalog-check.json').write_text(json.dumps({'status':'completed','checked_at':'2026-10-21T12:00:00Z',
                        'contexts':[{'family':'11','release':'26H2','architecture':'x64','dotnet':'4.8.1','compared_run':RUN,
                            'groups':[{'kb':'KB5128000','title':'Fixture new cumulative','published':'2026-10-21','new':True}]}]}))
                    route.fulfill(status=202,content_type='application/json',body='{"accepted":true}')
                page.route('**/api/maintenance/windows/check',catalog)
                page.get_by_role('button',name='Verifier les nouveaux correctifs',exact=True).click()
                expect(page.locator('#windows-maintenance-catalog')).to_contain_text('KB5128000')
                expect(page.locator('#windows-maintenance-catalog')).to_contain_text('Nouveau correctif')
                page.screenshot(path='/tmp/atelier-maintenance-windows.png',full_page=True)
                page.set_viewport_size({'width':390,'height':844})
                assert page.evaluate('document.documentElement.scrollWidth<=window.innerWidth'),page.evaluate("[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().right>innerWidth+1).slice(0,15).map(e=>({tag:e.tagName,id:e.id,cls:e.className,right:e.getBoundingClientRect().right}))")
                page.screenshot(path='/tmp/atelier-maintenance-mobile.png',full_page=True)
                page.get_by_role('button',name='HPIA et pilotes',exact=True).click()
                expect(page.locator('#hp-maintenance-models')).to_contain_text('SP12345')
                assert page.evaluate('document.documentElement.scrollWidth<=window.innerWidth')
                assert not errors,errors
                browser.close()
            print('Maintenance browser passed: models, CVA, storage, KBs, report download, escaping, search and mobile layout.')
        finally:process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
