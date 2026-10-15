"""Exercise the local IQ page with a simulated webcam and human selections."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import threading

from playwright.sync_api import expect, sync_playwright

ROOT=Path(__file__).resolve().parents[1]


def run():
    received=[]
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers()
            self.wfile.write((ROOT/'scripts'/'Tests-Materiel.html').read_bytes())

        def do_POST(self):
            assert self.path=='/test/result'
            received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"saved":true}')

        def log_message(self,*args):
            pass

    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with sync_playwright() as p:
            browser=p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox','--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream'])
            page=browser.new_page();errors=[];page.on('pageerror',lambda error:errors.append(str(error)))
            page.goto(f'http://localhost:{server.server_port}/test/')
            page.locator('#left').click();expect(page.locator('#audio-info')).to_contain_text('gauche')
            page.locator('#right').click();expect(page.locator('#audio-info')).to_contain_text('droit')
            page.locator('#camera').click()
            page.wait_for_function("document.getElementById('preview').videoWidth > 0")
            page.locator('#keyboard').focus();page.keyboard.press('a');page.keyboard.press('ArrowLeft')
            expect(page.locator('#key-KeyA')).to_have_class('key pressed')
            expect(page.locator('#key-ArrowLeft')).to_have_class('key pressed')
            page.locator('#son').select_option('passed');page.locator('#webcam').select_option('passed')
            page.locator('#clavier').select_option('failed');page.locator('#clavier-comment').fill('Une touche manque')
            page.locator('#save').click();expect(page.locator('#notice')).to_contain_text('Résultats enregistrés')
            assert received[0]['tests'][2]['status']=='failed'
            assert page.evaluate("document.getElementById('preview').srcObject === null")
            assert not errors,errors
            browser.close()
    finally:
        server.shutdown();server.server_close();thread.join()
    print('IQ browser passed: audio channels, simulated camera, keyboard, operator results, saved JSON, camera stopped.')


if __name__=='__main__':
    run()
