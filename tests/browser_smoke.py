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


def run(internal=False):
    chromium = shutil.which('chromium') or shutil.which('google-chrome')
    if not chromium:
        raise RuntimeError('Chromium est requis pour ce test navigateur.')
    with tempfile.TemporaryDirectory(prefix='atelier-browser-') as folder:
        data = Path(folder)
        (data / 'artifacts').mkdir()
        (data / 'artifacts' / 'lab.wim').write_bytes(b'MSWIM\0\0\0' + b'not-a-real-wim' * 20)
        (data / 'artifacts' / 'vlc.exe').write_bytes(b'unsigned-test-installer-not-executed')
        (data / 'artifacts' / 'hp.zip').write_bytes(b'test-archive-not-extracted')
        (data / 'artifacts' / 'desktop.png').write_bytes(b'\x89PNG\r\n\x1a\nnot-a-real-wallpaper')
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        origin = f'http://127.0.0.1:{port}'
        admin = secrets.token_urlsafe(32)
        env = {**os.environ, 'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':admin,'MDT_BASE_URL':origin,'MDT_INTERNAL_MODE':'1' if internal else '0','MDT_AUTOMATIC_WINDOWS':'1' if internal else '0'}
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
                if internal:
                    expect(page.locator('#connection')).to_have_text('● Console connectée')
                    assert not page.locator('#login-dialog').is_visible()
                    assert not page.locator('#logout').is_visible()
                else:
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
                page.locator('[data-page="software"]').click()
                for filename, kind in [('vlc.exe','application'),('hp.zip','application'),('desktop.png','wallpaper')]:
                    page.get_by_role('button',name='Enregistrer un installateur ou votre fond d’écran →',exact=True).click()
                    page.get_by_label('Nom exact du fichier').fill(filename)
                    page.get_by_label('Type',exact=True).select_option(kind)
                    page.locator('#submit-resource').click()
                    page.wait_for_selector('#form-dialog',state='hidden')
                for name, filename, manufacturer, mode, entry in [
                    ('VLC','vlc.exe','all','install',''),
                    ('HP Image Assistant','hp.zip','hp','portable','HPImageAssistant.exe')]:
                    page.get_by_role('button',name='＋ Ajouter un logiciel',exact=True).click()
                    page.get_by_label('Nom du logiciel',exact=True).fill(name)
                    page.get_by_label('Version du logiciel',exact=True).fill('test')
                    page.get_by_label('Fichier du logiciel',exact=True).select_option(label=filename)
                    page.get_by_label('Constructeur compatible').select_option(manufacturer)
                    page.get_by_label('Mode',exact=True).select_option(mode)
                    page.get_by_label('Programme dans le ZIP').fill(entry)
                    page.locator('#submit-resource').click()
                    page.wait_for_selector('#form-dialog',state='hidden')
                page.get_by_role('button',name='＋ Créer un bundle',exact=True).click()
                page.get_by_label('Nom du bundle').fill('Atelier standard')
                page.get_by_label('VLC test · all',exact=True).check()
                page.get_by_label('HP Image Assistant test · hp',exact=True).check()
                page.locator('#submit-resource').click()
                page.wait_for_selector('#form-dialog',state='hidden')
                expect(page.locator('#applications .profile-card')).to_have_count(2)
                expect(page.locator('#bundles .profile-card')).to_have_count(1)
                page.screenshot(path='/tmp/atelier-software.png',full_page=True)
                page.locator('[data-page="profiles"]').click()
                page.get_by_role('button',name='＋ Nouveau profil',exact=True).click()
                page.get_by_label('Nom du profil').fill('Windows 11 · Laboratoire')
                page.get_by_label('Image Windows',exact=True).select_option(index=1)
                page.get_by_label('Version Windows',exact=True).fill('26H2')
                page.get_by_label('Édition',exact=True).fill('Pro')
                page.get_by_label('Thème Windows').select_option('dark')
                page.get_by_label('Fond d’écran',exact=True).select_option(label='desktop.png')
                page.get_by_label('Atelier standard',exact=True).check()
                page.locator('#submit-resource').click()
                page.wait_for_selector('#form-dialog',state='hidden')
                with urlopen(Request(origin+'/api/state',headers={'Authorization':'Bearer '+admin})) as response:
                    saved = json.load(response)['profiles'][0]
                assert saved['windows_version'] == '26H2' and saved['settings']['theme'] == 'dark'
                assert saved['settings']['wallpaper_asset_id'] and len(saved['settings']['bundle_ids']) == 1
                page.locator('[data-page="overview"]').click()

                def create_job():
                    page.get_by_role('button',name='＋ Nouveau déploiement',exact=True).click()
                    page.get_by_label('Poste cible').select_option(index=1)
                    page.get_by_label('Profil Windows',exact=True).select_option(index=1)
                    if internal:
                        assert page.locator('input[name="confirmation"]').count() == 0
                        with page.expect_response(lambda r: r.url.endswith('/api/deployments') and r.request.method == 'POST') as created:
                            page.locator('#submit-resource').click()
                        result = created.value.json()
                        page.wait_for_selector('#form-dialog',state='hidden')
                        assert result['boot_code'] is None
                        assert not page.locator('#token-dialog').is_visible()
                        return result['id'], result['agent_token']
                    page.get_by_label('Confirmation : EFFACER suivi du nom exact du poste').fill('EFFACER PC-LAB-01')
                    page.locator('#submit-resource').click()
                    page.wait_for_selector('#token-dialog[open]')
                    identifier = page.locator('#job-id').input_value()
                    agent_token = page.locator('#job-token').input_value()
                    assert len(page.locator('#boot-code').input_value()) == 24
                    page.locator('[data-close="token-dialog"]').click()
                    assert not page.locator('#job-token').input_value()
                    assert not page.locator('#boot-code').input_value()
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
            print(('Internal mode: ' if internal else 'Authenticated mode: ') + 'Browser smoke passed: authentication, machine/image/software/bundle/profile forms, saved personalization, PXE code cleared, agent lifecycle, journal, cancellation, mobile layout; no JavaScript errors.')
        finally:
            process.terminate()
            process.wait(timeout=10)


if __name__ == '__main__':
    run()
    run(internal=True)
