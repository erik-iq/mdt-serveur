"""Exercise a computer sheet, notes, history and stage times in a real browser."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.request import Request,urlopen
from playwright.sync_api import expect,sync_playwright

ROOT=Path(__file__).resolve().parents[1]


def run():
    with tempfile.TemporaryDirectory(prefix='computer-browser-') as folder:
        data=Path(folder);(data/'artifacts').mkdir();(data/'artifacts'/'lab.wim').write_bytes(b'MSWIM\0\0\0fixture')
        with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        origin=f'http://127.0.0.1:{port}'
        env={**os.environ,'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':'fixture-admin-token-not-a-secret','MDT_BASE_URL':origin,'MDT_INTERNAL_MODE':'1','MDT_AUTO_ENROLL':'1','MDT_CLIENT_SOFTWARE':'1'}
        process=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:create_app','--factory','--host','127.0.0.1','--port',str(port)],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
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
            profile=api('/profiles',{'name':'Windows atelier','asset_id':image['id']})
            session=api('/boot/discover',{'macs':['00:11:22:33:44:55'],'release':'ATELIER-4'})
            identifier=session['id'];token=session['agent_token']
            api('/agent/'+identifier+'/configure',{'profile_id':profile['id'],'hostname':'PC-8323','settings':profile['settings']},token)
            reporter=api('/agent/'+identifier+'/claim',{},token)['report_token']
            api('/agent/'+identifier+'/events',{'status':'staged','progress':100,'message':'Image appliquee'},token)
            api('/windows/'+identifier+'/timings',{'measurements':[{'run_id':str(uuid.uuid4()),'source':'winpe','stage':'image','status':'completed','started_at':'2026-10-19T09:00:00Z','duration_seconds':125}]},reporter)
            report={'hostname':'PC-8323','status':'completed','generated_at':'2026-10-19T09:15:00Z','inventory':{'Constructeur':'HP','Modele':'EliteBook','Numero de serie':'SN8323','Windows':'Windows 11 Pro','Garantie constructeur':'active_confirmee_operateur','Garantie debut / fin':'2025-01-01 / 2028-01-01'},'steps':[{'name':'Test webcam','status':'passed','message':'Test operateur'}],'warnings':[]}
            api('/windows/'+identifier+'/report',report,reporter)
            with sync_playwright() as p:
                browser=p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
                page=browser.new_page(viewport={'width':1440,'height':1100});errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
                page.goto(origin);expect(page.locator('#connection')).to_have_text('Console connectee')
                page.get_by_role('button',name='Fiche ordinateur',exact=True).click()
                expect(page.locator('#computer-title')).to_have_text('PC-8323')
                expect(page.locator('#computer-summary')).to_contain_text('SN8323')
                page.get_by_text('Durees par etape',exact=True).click()
                expect(page.locator('#computer-history')).to_contain_text('2 min 5 s')
                expect(page.locator('#computer-report')).to_contain_text('Test webcam')
                expect(page.locator('#computer-report')).to_contain_text('2028-01-01')
                page.get_by_label('Technicien (facultatif)').fill('Erik')
                page.get_by_label('Observation',exact=True).fill('Ecran verifie <script>test</script>')
                page.get_by_role('button',name='Ajouter l observation',exact=True).click()
                expect(page.locator('#computer-notes')).to_contain_text('Ecran verifie <script>test</script>')
                assert page.locator('#computer-notes script').count()==0
                page.screenshot(path='/tmp/atelier-computer.png',full_page=True)
                page.reload();expect(page.locator('#connection')).to_have_text('Console connectee')
                page.locator('[data-page="machines"]').click();page.locator('#machines [data-computer]').click()
                expect(page.locator('#computer-notes')).to_contain_text('Ecran verifie')
                page.set_viewport_size({'width':390,'height':844});assert page.evaluate('document.documentElement.scrollWidth<=window.innerWidth')
                page.screenshot(path='/tmp/atelier-computer-mobile.png',full_page=True)
                assert not errors,errors
                browser.close()
            print('Computer browser passed: machine identity, history, measured durations, tests, warranty, persistent escaped notes, mobile layout.')
        finally:process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
