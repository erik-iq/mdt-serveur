"""Reproduce stale CSS with oversized branding, then verify the corrected page."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

from playwright.sync_api import expect, sync_playwright

ROOT=Path(__file__).resolve().parents[1]
# The previous stylesheet had no rule for the new logo image.
LEGACY_CSS='''body{margin:0;background:#f6f8f7} .sidebar{position:fixed;inset:0 auto 0 0;width:238px;background:#122a2e}.shell{margin-left:238px}.topbar{display:flex;justify-content:space-between;padding:0 42px;height:77px}.topbar>div{display:flex;align-items:center;gap:23px}.heading{background:none}'''


def assert_logo(page):
    logo=page.locator('.topbar .brand-logo')
    expect(logo).to_have_count(1)
    assert page.locator('.sidebar img').count()==0
    box=logo.bounding_box()
    header=page.locator('.topbar').bounding_box()
    assert box and header
    assert box['width']==40 and box['height']==40,box
    assert header['x']+header['width']-55 <= box['x']+box['width'] <= header['x']+header['width'],box
    assert header['y'] <= box['y'] and box['y']+box['height'] <= header['y']+header['height'],box


def run():
    with tempfile.TemporaryDirectory(prefix='iq-theme-') as folder:
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0));port=reservation.getsockname()[1]
        origin=f'http://127.0.0.1:{port}'
        env={**os.environ,'MDT_DATA_DIR':folder,'MDT_ADMIN_TOKEN':'fixture-admin-token-not-a-secret','MDT_BASE_URL':origin,'MDT_INTERNAL_MODE':'1','MDT_CLIENT_SOFTWARE':'1','MDT_AUTO_ENROLL':'1','MDT_AUTOMATIC_WINDOWS':'1'}
        process=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:create_app','--factory','--host','127.0.0.1','--port',str(port)],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                try:
                    with urlopen(origin+'/health',timeout=1):break
                except OSError:time.sleep(.1)
            with sync_playwright() as p:
                browser=p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
                context=browser.new_context(viewport={'width':1440,'height':1000});page=context.new_page();errors=[]
                page.on('pageerror',lambda e:errors.append(str(e)))
                # A stale asset at the original address must never be used by new HTML.
                page.route('**/static/style.css',lambda route:route.fulfill(body=LEGACY_CSS,content_type='text/css'))
                legacy=(ROOT/'app'/'static'/'index.html').read_text().replace(' width="40" height="40"','')
                page.route('**/legacy-theme',lambda route:route.fulfill(body=legacy,content_type='text/html'))
                page.goto(origin+'/legacy-theme');page.wait_for_function('document.querySelector(".brand-logo").naturalWidth>0')
                assert page.locator('.brand-logo').bounding_box()['width']>500
                assert page.locator('.sidebar').evaluate('(el)=>getComputedStyle(el).backgroundColor')=='rgb(18, 42, 46)'
                response=page.goto(origin)
                assert response.headers['cache-control']=='no-store'
                css=page.locator('link[rel="stylesheet"]').get_attribute('href')
                assert css=='/static/style.css?v='+hashlib.sha256((ROOT/'app'/'static'/'style.css').read_bytes()).hexdigest()[:16]
                expect(page.locator('#connection')).to_have_text('Console connectée')
                assert_logo(page)
                gradient=page.locator('.heading').first.evaluate('(el)=>getComputedStyle(el).backgroundImage')
                assert 'rgb(230, 241, 250)' in gradient and 'rgb(237, 241, 255)' in gradient,gradient
                sidebar=page.locator('.sidebar').evaluate('(el)=>getComputedStyle(el).backgroundImage')
                assert 'linear-gradient' in sidebar
                assert page.locator('[data-page]').count()==5
                for width,height,name in [(1440,1000,'desktop'),(390,844,'mobile'),(1920,1080,'large')]:
                    page.set_viewport_size({'width':width,'height':height})
                    assert_logo(page)
                    assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
                    page.screenshot(path='/tmp/iq-theme-'+name+'.png',full_page=True)
                # Choix explicite, conservation après rechargement et adaptation au système.
                page.set_viewport_size({'width':1440,'height':1000})
                picker=page.get_by_label('Thème du site',exact=True)
                page.mouse.move(0,0)
                picker.select_option('dark')
                expect(page.locator('html')).to_have_attribute('data-theme','dark')
                assert page.locator('body').evaluate('(el)=>getComputedStyle(el).backgroundColor')=='rgb(11, 20, 35)'
                expect(page.locator('.empty .secondary')).to_have_css('background-color','rgb(26, 44, 67)')
                page.screenshot(path='/tmp/iq-theme-night-desktop.png',full_page=True)
                page.get_by_role('button',name='Enregistrer une machine',exact=True).click()
                expect(page.locator('#form-dialog')).to_be_visible()
                assert page.locator('#form-dialog').evaluate('(el)=>getComputedStyle(el).backgroundColor')=='rgb(19, 34, 56)'
                page.locator('#form-dialog').get_by_role('button',name='Fermer',exact=True).click()
                page.reload()
                expect(picker).to_have_value('dark')
                expect(page.locator('html')).to_have_attribute('data-theme','dark')
                other=page.context.new_page();other.goto(origin)
                expect(other.locator('html')).to_have_attribute('data-theme','dark')
                picker.select_option('light')
                expect(page.locator('html')).to_have_attribute('data-theme','light')
                expect(other.locator('html')).to_have_attribute('data-theme','light')
                other.close()
                picker.select_option('auto')
                page.emulate_media(color_scheme='dark')
                expect(page.locator('html')).to_have_attribute('data-theme','dark')
                page.emulate_media(color_scheme='light')
                expect(page.locator('html')).to_have_attribute('data-theme','light')
                picker.select_option('dark')
                page.emulate_media(color_scheme='light')
                expect(page.locator('html')).to_have_attribute('data-theme','dark')
                page.set_viewport_size({'width':390,'height':844})
                assert_logo(page)
                expect(picker).to_be_visible()
                assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
                page.screenshot(path='/tmp/iq-theme-night-mobile.png',full_page=True)
                # Un navigateur qui refuse le stockage permet encore le changement de thème.
                isolated=browser.new_context(color_scheme='dark')
                isolated.add_init_script("Object.defineProperty(window,'localStorage',{get(){throw new DOMException('Stockage indisponible','SecurityError')}})")
                restricted=isolated.new_page();restricted.on('pageerror',lambda e:errors.append(str(e)))
                restricted.goto(origin)
                expect(restricted.locator('html')).to_have_attribute('data-theme','dark')
                restricted.get_by_label('Thème du site').select_option('light')
                expect(restricted.locator('html')).to_have_attribute('data-theme','light')
                isolated.close()
                picker.select_option('auto')
                page.emulate_media(color_scheme='light')
                # Even a failed proxy returning legacy CSS cannot make the logo huge.
                page.route('**/static/style.css?*',lambda route:route.fulfill(body=LEGACY_CSS,content_type='text/css'))
                page.set_viewport_size({'width':1440,'height':1000});page.reload();assert_logo(page)
                assert not errors,errors
                browser.close()
            print('Thème browser passed: stale CSS reproduces the fault; content versions restore the high contrast interface; logo is 40x40 at top right on desktop/mobile/large and with legacy CSS.')
        finally:
            process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
