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
                page=browser.new_page(viewport={'width':1440,'height':1000});errors=[]
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
                expect(page.locator('#connection')).to_have_text('Console connectee')
                assert_logo(page)
                gradient=page.locator('.heading').first.evaluate('(el)=>getComputedStyle(el).backgroundImage')
                assert 'rgb(210, 228, 241)' in gradient and 'rgb(233, 217, 234)' in gradient,gradient
                sidebar=page.locator('.sidebar').evaluate('(el)=>getComputedStyle(el).backgroundImage')
                assert 'linear-gradient' in sidebar
                assert page.locator('[data-page]').count()==3
                for width,height,name in [(1440,1000,'desktop'),(390,844,'mobile'),(1920,1080,'large')]:
                    page.set_viewport_size({'width':width,'height':height})
                    assert_logo(page)
                    assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
                    page.screenshot(path='/tmp/iq-theme-'+name+'.png',full_page=True)
                # Even a failed proxy returning legacy CSS cannot make the logo huge.
                page.route('**/static/style.css?*',lambda route:route.fulfill(body=LEGACY_CSS,content_type='text/css'))
                page.set_viewport_size({'width':1440,'height':1000});page.reload();assert_logo(page)
                assert not errors,errors
                browser.close()
            print('Theme browser passed: stale CSS reproduces the fault; content versions restore blue/lilac; logo is 40x40 at top right on desktop/mobile/large and with legacy CSS.')
        finally:
            process.terminate();process.wait(timeout=10)


if __name__=='__main__':run()
