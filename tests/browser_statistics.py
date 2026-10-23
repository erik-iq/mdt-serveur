"""Statistiques réelles via HTTP, filtres, erreurs réseau et rendu clair ou sombre."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen

from playwright.sync_api import expect, sync_playwright

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from test_statistics import measure, seed


def run():
    with tempfile.TemporaryDirectory(prefix='statistics-browser-') as folder:
        data=Path(folder);(data/'artifacts').mkdir();(data/'artifacts/lab.wim').write_bytes(b'MSWIM\0\0\0fixture')
        with socket.socket() as reservation:reservation.bind(('127.0.0.1',0));port=reservation.getsockname()[1]
        origin=f'http://127.0.0.1:{port}'
        env={**os.environ,'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':'fixture-browser-statistics-token',
             'MDT_BASE_URL':origin,'MDT_INTERNAL_MODE':'1','MDT_AUTO_ENROLL':'1','MDT_CLIENT_SOFTWARE':'1'}
        process=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:create_app','--factory','--host','127.0.0.1','--port',str(port)],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        def api(path,body):
            with urlopen(Request(origin+'/api'+path,data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})) as response:return json.load(response)
        try:
            for _ in range(100):
                try:
                    with urlopen(origin+'/health',timeout=1):break
                except OSError:time.sleep(.1)
            image=api('/assets',{'filename':'lab.wim','kind':'windows'})
            profile=api('/profiles',{'name':'Windows 11 Pro FR','asset_id':image['id']})
            machine=api('/machines',{'hostname':'PC-STATS','serial_number':'STATISTICS-8323'})
            with sync_playwright() as playwright:
                browser=playwright.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
                page=browser.new_page(viewport={'width':1440,'height':1050});errors=[]
                page.on('pageerror',lambda error:errors.append(str(error)))
                page.goto(origin);expect(page.locator('#connection')).to_have_text('Console connectée')
                page.get_by_role('button',name='Statistiques',exact=True).click()
                expect(page.locator('#statistics-models')).to_contain_text('Aucun résultat définitif')
                expect(page.locator('#statistics-stages')).to_contain_text('Pas encore de chronométrages')
                expect(page.locator('#statistics-summary')).to_contain_text('Non disponible')
                recent=(datetime.now(timezone.utc)-timedelta(days=1)).isoformat()
                model='EliteBook <840> & G5'
                seed(data,machine,profile,created=recent,model=model,timing=[measure('image',120,source='winpe'),measure('software',300,10),measure('hp_updates',600,12)])
                seed(data,machine,profile,created=recent,model=model,timing=[measure('image',60,source='winpe'),measure('software',180,10)])
                seed(data,machine,profile,created=recent,result='needs_attention',model=model)
                seed(data,machine,profile,created=recent,state='failed',result=None,report=False)
                seed(data,machine,profile,created=recent,result=None,report=False)
                seed(data,machine,profile,created=recent,result='running',report=False)
                seed(data,machine,profile,created=recent,state='cancelled')
                seed(data,machine,profile,created='2000-01-01T00:00:00Z',model='Latitude 5440',manufacturer='Dell')
                page.get_by_role('button',name='Actualiser les statistiques',exact=True).click()
                expect(page.locator('#statistics-summary strong').nth(0)).to_have_text('4')
                expect(page.locator('#statistics-summary strong').nth(1)).to_have_text('50 %')
                expect(page.locator('#statistics-summary strong').nth(2)).to_have_text('9 min 0 s')
                expect(page.locator('#statistics-models')).to_contain_text(model)
                assert page.locator('#statistics-models img, #statistics-models script, #statistics-models fixture').count()==0
                expect(page.locator('#statistics-stages h3').first).to_contain_text('Mises à jour HP')
                expect(page.locator('#statistics-stages')).to_contain_text('10 min 0 s')
                page.locator('#statistics-period').select_option('0')
                expect(page.locator('#statistics-summary strong').nth(0)).to_have_text('5')
                expect(page.locator('#statistics-summary strong').nth(1)).to_have_text('60 %')
                expect(page.locator('#statistics-models')).to_contain_text('Latitude 5440')
                requests=[]
                page.on('request',lambda request:requests.append(request.url))
                page.evaluate('Promise.all([loadStatistics(true),loadStatistics(true)])')
                assert len([url for url in requests if '/api/statistics/deployments' in url])==1,requests
                page.screenshot(path='/tmp/atelier-statistics-light.png',full_page=True)
                page.route('**/api/statistics/deployments?*',lambda route:route.fulfill(status=503,content_type='application/json',body='{"detail":"Statistiques temporairement indisponibles"}'))
                page.get_by_role('button',name='Actualiser les statistiques',exact=True).click()
                expect(page.locator('#statistics-status')).to_contain_text('Actualisation impossible')
                expect(page.locator('#statistics-summary strong').nth(0)).to_have_text('5')
                page.unroute('**/api/statistics/deployments?*')
                page.get_by_role('button',name='Actualiser les statistiques',exact=True).click()
                expect(page.locator('#statistics-status')).to_contain_text('Actualisé le')
                page.get_by_label('Thème du site',exact=True).select_option('dark')
                page.set_viewport_size({'width':390,'height':844})
                assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
                page.screenshot(path='/tmp/atelier-statistics-dark-mobile.png',full_page=True)
                assert not errors,errors
                browser.close()
            print('Statistiques vérifiées : périodes, taux, durées, historique, échappement, requêtes simultanées, erreur réseau et mobile sombre.')
        finally:process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
