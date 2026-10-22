"""Real browser test of automatic arrival, client WinGet settings, and the server inventory folder."""
import json
import io
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import zipfile
from urllib.request import Request,urlopen

from playwright.sync_api import sync_playwright,expect

ROOT=Path(__file__).resolve().parents[1]


def run():
    chromium=shutil.which('chromium') or shutil.which('google-chrome')
    with tempfile.TemporaryDirectory(prefix='atelier3-browser-') as folder:
        data=Path(folder);(data/'artifacts').mkdir();(data/'artifacts'/'lab.wim').write_bytes(b'MSWIM\0\0\0'+b'fixture')
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0));port=reservation.getsockname()[1]
        origin=f'http://127.0.0.1:{port}'
        env={**os.environ,'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':'fixture-admin-token-not-a-secret','MDT_BASE_URL':origin,
             'MDT_INTERNAL_MODE':'1','MDT_AUTOMATIC_WINDOWS':'1','MDT_AUTO_ENROLL':'1','MDT_CLIENT_SOFTWARE':'1'}
        process=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:create_app','--factory','--host','127.0.0.1','--port',str(port)],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        def api(path,body=None,token=None,raw=None):
            headers={'Content-Type':'application/json'}
            if token:headers['Authorization']='Bearer '+token
            request=Request(origin+'/api'+path,method='POST' if body is not None or raw is not None else 'GET',headers=headers,
                            data=raw if raw is not None else (json.dumps(body).encode() if body is not None else None))
            with urlopen(request) as response:return json.load(response)
        try:
            for _ in range(100):
                try:
                    with urlopen(origin+'/health',timeout=1):break
                except OSError:time.sleep(.1)
            asset=api('/assets',{'filename':'lab.wim','kind':'windows'})
            initial=api('/profiles',{'name':'Windows Pro','edition':'Pro','asset_id':asset['id']})
            with sync_playwright() as p:
                browser=p.chromium.launch(executable_path=chromium,headless=True,args=['--no-sandbox'])
                page=browser.new_page(viewport={'width':1440,'height':1000});errors=[]
                page.on('pageerror',lambda error:errors.append(str(error)))
                page.goto(origin);expect(page.locator('#connection')).to_have_text('Console connectée')
                expect(page.get_by_role('button',name='+ Nouveau deploiement',exact=True)).to_be_hidden()
                expect(page.locator('[data-page]')).to_have_count(3)
                expect(page.locator('#page-software, #page-boot')).to_have_count(0)
                assert page.locator('.brand-logo').evaluate('(img)=>img.complete && img.naturalWidth>0')
                assert page.locator('body').evaluate('(el)=>getComputedStyle(el).getPropertyValue("--accent").trim()')=='#4869B5'
                page.locator('[data-page="profiles"]').click();page.get_by_role('button',name='+ Nouveau profil',exact=True).click()
                page.get_by_label('Nom du profil').fill('Windows atelier 3')
                page.get_by_label('Image Windows',exact=True).select_option(asset['id'])
                expect(page.get_by_label('HP Image Assistant',exact=True)).not_to_be_checked()
                expect(page.get_by_label('Lenovo System Update',exact=True)).not_to_be_checked()
                page.get_by_role('button',name='Bundle HP',exact=True).click()
                expect(page.get_by_label('HP Image Assistant',exact=True)).to_be_checked()
                expect(page.get_by_label('Lenovo System Update',exact=True)).not_to_be_checked()
                page.get_by_role('button',name='Bundle Lenovo',exact=True).click()
                expect(page.get_by_label('HP Image Assistant',exact=True)).not_to_be_checked()
                expect(page.get_by_label('Lenovo System Update',exact=True)).to_be_checked()
                page.get_by_label('Adobe Reader',exact=True).uncheck();page.get_by_label('AnyDesk',exact=True).uncheck()
                page.locator('#submit-resource').click();page.wait_for_selector('#form-dialog',state='hidden')
                state=api('/state');profile=next(x for x in state['profiles'] if x['name']=='Windows atelier 3')
                assert profile['settings']['winget_packages']==['vlc','chrome','lenovo_system_update']
                session=api('/boot/discover',{'serial_number':'HP-BROWSER3-0001','macs':[],'release':'ATELIER-4'});identifier=session['id'];token=session['agent_token']
                api('/agent/'+identifier+'/configure',{'profile_id':profile['id'],'hostname':'PC-BROWSER3','disk_number':1,'settings':profile['settings']},token)
                page.locator('[data-page="overview"]').click();page.evaluate('refresh()')
                row=page.locator('[data-job="'+identifier+'"]');expect(row).to_contain_text('PC-BROWSER3');expect(row).to_contain_text('SN : HP-BROWSER3-0001')
                row.locator('[data-inventory]').click();expect(page.locator('#inventory-files')).to_contain_text('En attente')
                page.locator('[data-close="inventory-dialog"]').click()
                reporter=api('/agent/'+identifier+'/claim',{},token)['report_token']
                hp_profile=api('/profiles',{'name':'HP cache lab','asset_id':asset['id'],'settings':{'software_mode':'winget','winget_packages':['hpia']}})
                hp_session=api('/boot/discover',{'serial_number':'HP-BROWSER3-0002','macs':['00:11:22:33:44:55'],'release':'ATELIER-4'})
                api('/agent/'+hp_session['id']+'/configure',{'profile_id':hp_profile['id'],'hostname':'HP-BROWSER','disk_number':0,'settings':hp_profile['settings']},hp_session['agent_token'])
                hp_token=api('/agent/'+hp_session['id']+'/claim',{},hp_session['agent_token'])['report_token']
                api('/windows/'+hp_session['id']+'/hp-repository',{'platform':'8AB8','os':'win11','os_version':'25H2','required_softpaqs':['SP12345']},hp_token)
                page.evaluate('refresh()');page.locator('#hp-repository-panel summary').click()
                expect(page.locator('#hp-repository-jobs')).to_contain_text('HP 8AB8')
                page.get_by_role('button',name='Actualiser les pilotes HP',exact=True).click()
                expect(page.get_by_role('button',name='Actualiser les pilotes HP',exact=True)).to_be_enabled()
                assert len(api('/hp-repository')['jobs'])==1
                xml=b'<InventaireOrdinateur ordinateur="PC-BROWSER3"><Proprietes/></InventaireOrdinateur>'
                csv=b'Ordinateur;Categorie;Propriete;Valeur\nPC-BROWSER3;RAM;Go;16\n'
                api('/windows/'+identifier+'/inventory/xml',token=reporter,raw=xml)
                api('/windows/'+identifier+'/inventory/csv',token=reporter,raw=csv)
                log_stream=io.BytesIO()
                with zipfile.ZipFile(log_stream,'w') as z:
                    z.writestr('result.json','{"status":"completed"}')
                    z.writestr('maintenance.json','{"status":"completed"}')
                api('/windows/'+identifier+'/inventory/diagnostics',token=reporter,raw=log_stream.getvalue())
                hp_stream=io.BytesIO()
                with zipfile.ZipFile(hp_stream,'w') as z:z.writestr('hpia-result.json','{"status":"not_run"}')
                api('/windows/'+identifier+'/inventory/hp_reports',token=reporter,raw=hp_stream.getvalue())
                api('/windows/'+identifier+'/report',token=reporter,body={'hostname':'PC-BROWSER3','status':'completed','generated_at':'2026-10-20T12:00:00Z','inventory':{'Modele':'Test'},'steps':[],'warnings':[]})
                page.evaluate('refresh()');row.locator('[data-inventory]').click()
                expect(page.locator('#inventory-directory')).to_have_value(str(data/'inventaires'/'PC-BROWSER3'/identifier))
                with page.expect_download() as download:
                    page.get_by_role('button',name='Telecharger Inventaire-Technique.csv',exact=True).click()
                assert Path(download.value.path()).read_bytes()==csv
                page.screenshot(path='/tmp/atelier3-inventory.png',full_page=True)
                page.locator('[data-close="inventory-dialog"]').click()
                page.goto(origin+'?deployment='+identifier+'&view=inventory')
                expect(page.locator('#inventory-dialog')).to_be_visible()
                with page.expect_download() as diagnostic_download:
                    page.get_by_role('button',name='Telecharger Diagnostics-Deploiement.zip',exact=True).click()
                assert Path(diagnostic_download.value.path()).read_bytes()==log_stream.getvalue()
                with page.expect_download() as hp_download:
                    page.get_by_role('button',name='Telecharger Rapports-HP.zip',exact=True).click()
                assert Path(hp_download.value.path()).read_bytes()==hp_stream.getvalue()
                page.goto(origin+'?deployment='+identifier+'&view=report')
                expect(page.locator('#page-computer')).to_be_visible()
                expect(page.locator('#computer-report')).to_contain_text('Rapport du')
                page.set_viewport_size({'width':390,'height':844})
                assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
                page.screenshot(path='/tmp/atelier3-mobile.png',full_page=True)
                page.locator('[data-page="overview"]').click()
                if not page.locator('#hp-repository-panel').evaluate('(el)=>el.open'):page.locator('#hp-repository-panel summary').click()
                expect(page.locator('#hp-repository-jobs')).to_contain_text('HP 8AB8')
                assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
                assert not errors,errors
                browser.close()
            print('ATELIER-4 browser passed: no site authorization, software choices, automatic machine activity, server inventory directory and CSV download; no JavaScript errors.')
        finally:
            process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
