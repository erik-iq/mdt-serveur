"""Actual browser workflow against an isolated HTTP server and synthetic images."""
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parent.parent


def run():
    chromium = shutil.which('chromium') or shutil.which('google-chrome')
    if not chromium:
        raise RuntimeError('Chromium est requis pour ce test navigateur.')
    with tempfile.TemporaryDirectory(prefix='atelier-browser-') as folder:
        data = Path(folder)
        (data / 'artifacts').mkdir()
        (data / 'artifacts' / 'lab.wim').write_bytes(b'MSWIM\0\0\0' + b'not-a-real-wim' * 20)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        origin = f'http://127.0.0.1:{port}'
        admin = secrets.token_urlsafe(32)
        env = {**os.environ, 'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':admin,'MDT_BASE_URL':origin}
        process = subprocess.Popen([sys.executable,'-m','uvicorn','app.main:create_app','--factory','--host','127.0.0.1','--port',str(port)],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                try:
                    with urlopen(origin+'/health', timeout=1) as response:
                        assert response.status == 200
                    break
                except OSError:
                    if process.poll() is not None:
                        raise RuntimeError('Le serveur de test a échoué au démarrage.')
                    time.sleep(.1)
            else:
                raise RuntimeError('Timeout au démarrage du serveur.')
            with sync_playwright() as p:
                browser = p.chromium.launch(executable_path=chromium, headless=True, args=['--no-sandbox'])
                page = browser.new_page(viewport={'width':1440,'height':1100}, timezone_id='Europe/Zurich')
                errors = []
                page.on('pageerror',lambda error: errors.append(str(error)))
                page.goto(origin)
                page.get_by_label('Jeton administrateur').fill(admin)
                page.get_by_role('button',name='Ouvrir la console').click()
                page.wait_for_selector('#login-dialog',state='hidden')
                page.get_by_role('button',name='Enregistrer une machine',exact=True).click()
                page.get_by_label('Nom Windows du poste').fill('PC-LAB-01')
                page.get_by_label('Adresse MAC PXE').fill('00:11:22:33:44:55')
                page.get_by_label('Description',exact=True).fill('Poste de laboratoire')
                page.locator('#submit-resource').click()
                page.wait_for_selector('#form-dialog',state='hidden')
                expect(page.locator('#metric-machines')).to_have_text('1')
                page.locator('[data-page="profiles"]').click()
                page.get_by_role('button',name='Enregistrer un fichier',exact=True).click()
                page.get_by_label('Nom exact du fichier').fill('lab.wim')
                page.get_by_label('Type',exact=True).select_option('windows')
                page.locator('#submit-resource').click()
                page.wait_for_selector('#form-dialog',state='hidden')
                page.get_by_role('button',name='＋ Nouveau profil',exact=True).click()
                page.get_by_label('Nom du profil').fill('Windows 11 · Laboratoire')
                page.get_by_label('Image Windows',exact=True).select_option(index=1)
                page.locator('#submit-resource').click()
                page.wait_for_selector('#form-dialog',state='hidden')
                page.locator('[data-page="overview"]').click()

                def create_job():
                    page.get_by_role('button',name='＋ Nouveau déploiement',exact=True).click()
                    page.get_by_label('Poste cible').select_option(index=1)
                    page.get_by_label('Profil Windows',exact=True).select_option(index=1)
                    page.get_by_label('Confirmation : EFFACER suivi du nom exact du poste').fill('EFFACER PC-LAB-01')
                    page.locator('#submit-resource').click()
                    page.wait_for_selector('#token-dialog[open]')
                    identifier = page.locator('#job-id').input_value()
                    agent_token = page.locator('#job-token').input_value()
                    page.locator('[data-close="token-dialog"]').click()
                    assert not page.locator('#job-token').input_value()
                    return identifier, agent_token

                identifier, agent_token = create_job()
                def callback(path, body=None):
                    request = Request(origin+'/api/agent/'+identifier+path,method='POST',headers={'Authorization':'Bearer '+agent_token,'Content-Type':'application/json'},data=json.dumps(body).encode() if body else b'')
                    with urlopen(request) as response:
                        assert response.status == 200
                callback('/claim')
                callback('/events',{'status':'running','progress':35,'message':'Test navigateur : image en cours'})
                page.locator('#refresh').click()
                page.locator(f'[data-job="{identifier}"] .badge.running').wait_for()
                callback('/events',{'status':'staged','progress':100,'message':'Test navigateur : image préparée, démarrage non vérifié'})
                page.locator('#refresh').click()
                page.locator(f'[data-job="{identifier}"] .badge.staged').wait_for()
                page.locator(f'[data-events="{identifier}"]').click()
                page.get_by_text('Test navigateur : image préparée, démarrage non vérifié',exact=True).wait_for()
                page.locator('[data-close="events-dialog"]').click()
                second_id, _ = create_job()
                page.on('dialog',lambda dialog:dialog.accept())
                page.locator(f'[data-cancel="{second_id}"]').click()
                page.locator(f'[data-job="{second_id}"] .badge.cancelled').wait_for()
                page.screenshot(path='/tmp/atelier-desktop.png',full_page=True)
                page.set_viewport_size({'width':390,'height':844})
                assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
                page.screenshot(path='/tmp/atelier-mobile.png',full_page=True)
                assert not errors, errors
                browser.close()
            print('Browser smoke passed: authentication, machine/image/profile forms, authorization, agent lifecycle, journal, cancellation, mobile layout; no JavaScript errors.')
        finally:
            process.terminate()
            process.wait(timeout=10)


if __name__ == '__main__':
    run()
