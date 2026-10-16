"""Real browser test of automatic arrival, client WinGet settings, and the server inventory folder."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
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
                page.goto(origin);expect(page.locator('#connection')).to_have_text('Console connectee')
                expect(page.get_by_role('button',name='+ Nouveau deploiement',exact=True)).to_be_hidden()
                expect(page.locator('[data-page]')).to_have_count(3)
                expect(page.locator('#page-software, #page-boot')).to_have_count(0)
                assert page.locator('.brand-logo').evaluate('(img)=>img.complete && img.naturalWidth>0')
                assert page.locator('body').evaluate('(el)=>getComputedStyle(el).getPropertyValue("--accent").trim()')=='#4869B5'
                page.locator('[data-page="profiles"]').click();page.get_by_role('button',name='+ Nouveau profil',exact=True).click()
                page.get_by_label('Nom du profil').fill('Windows atelier 3')
                page.get_by_label('Image Windows',exact=True).select_option(asset['id'])
                page.get_by_label('Adobe Reader',exact=True).uncheck();page.get_by_label('AnyDesk',exact=True).uncheck()
                page.locator('#submit-resource').click();page.wait_for_selector('#form-dialog',state='hidden')
                state=api('/state');profile=next(x for x in state['profiles'] if x['name']=='Windows atelier 3')
                assert profile['settings']['winget_packages']==['vlc','chrome']
                session=api('/boot/discover',{'macs':['00:11:22:33:44:55'],'release':'ATELIER-4'});identifier=session['id'];token=session['agent_token']
                api('/agent/'+identifier+'/configure',{'profile_id':profile['id'],'hostname':'PC-BROWSER3','disk_number':1,'settings':profile['settings']},token)
                page.locator('[data-page="overview"]').click();page.evaluate('refresh()')
                row=page.locator('[data-job="'+identifier+'"]');expect(row).to_contain_text('PC-BROWSER3')
                row.locator('[data-inventory]').click();expect(page.locator('#inventory-files')).to_contain_text('En attente')
                page.locator('[data-close="inventory-dialog"]').click()
                reporter=api('/agent/'+identifier+'/claim',{},token)['report_token']
                xml=b'<InventaireOrdinateur ordinateur="PC-BROWSER3"><Proprietes/></InventaireOrdinateur>'
                csv=b'Ordinateur;Categorie;Propriete;Valeur\nPC-BROWSER3;RAM;Go;16\n'
                api('/windows/'+identifier+'/inventory/xml',token=reporter,raw=xml)
                api('/windows/'+identifier+'/inventory/csv',token=reporter,raw=csv)
                page.evaluate('refresh()');row.locator('[data-inventory]').click()
                expect(page.locator('#inventory-directory')).to_have_value(str(data/'inventaires'/'PC-BROWSER3'/identifier))
                with page.expect_download() as download:
                    page.get_by_role('button',name='Telecharger Inventaire-Technique.csv',exact=True).click()
                assert Path(download.value.path()).read_bytes()==csv
                page.screenshot(path='/tmp/atelier3-inventory.png',full_page=True)
                page.locator('[data-close="inventory-dialog"]').click()
                page.set_viewport_size({'width':390,'height':844})
                assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
                page.screenshot(path='/tmp/atelier3-mobile.png',full_page=True)
                assert not errors,errors
                browser.close()
            print('ATELIER-4 browser passed: no site authorization, software choices, automatic machine activity, server inventory directory and CSV download; no JavaScript errors.')
        finally:
            process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
