"""Real authenticated HTTPS transport with a temporary trusted local test CA."""
import hashlib
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import uuid

import pytest

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('ATELIER_PWSH') or shutil.which('pwsh')
pytestmark=pytest.mark.skipif(not PWSH or not shutil.which('openssl'),reason='PowerShell and openssl required')


@pytest.mark.parametrize('case',['success','corrupt','wrong_length','redirect','wrong_url'])
def test_native_https_download_requires_integrity_and_never_redirects_credentials(tmp_path,case):
    certificate=tmp_path/'localhost.crt';key=tmp_path/'localhost.key'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(certificate),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign','-addext','extendedKeyUsage=serverAuth'],capture_output=True,check=True)
    content=b'Immutable snapshot bytes, never executed.'*3000
    identifier=str(uuid.uuid4());snapshot=str(uuid.uuid4())
    expected='/api/windows/'+identifier+'/hp-repository/'+snapshot+'.zip'
    calls=[]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):
            calls.append((self.path,self.headers.get('Authorization')))
            if case=='redirect':
                self.send_response(302);self.send_header('Location','https://must-not-be-contacted.invalid/private');self.send_header('Content-Length','0');self.end_headers();return
            self.send_response(200);self.send_header('Content-Length',str(len(content)+(1 if case=='wrong_length' else 0)));self.end_headers()
            try:self.wfile.write(b'X'+content[1:] if case=='corrupt' else content)
            except (ssl.SSLError,BrokenPipeError,ConnectionResetError):pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(certificate,key)
    server.socket=context.wrap_socket(server.socket,server_side=True)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    script=r'''
$ErrorActionPreference='Stop'
. 'LIBRARY'
$config=@{id='ID';server_url='ORIGIN';token='fixture-private-token'}
$snapshot=@{id='SNAPSHOT';url='URL';sha256='HASH';size=SIZE}
try {
 Receive-AtelierHpArchive -Config $config -Snapshot $snapshot -Path 'ROOT/cache.zip' -OnProgress {param($Message)}
 Receive-AtelierHpArchive -Config $config -Snapshot $snapshot -Path 'ROOT/cache.zip' -OnProgress {param($Message)}
 @{status='success'}|ConvertTo-Json|Set-Content 'ROOT/out.json'
} catch {@{status='failed';message=$_.Exception.Message}|ConvertTo-Json|Set-Content 'ROOT/out.json'}
'''.replace('LIBRARY',str(ROOT/'scripts'/'HP-ClientRepository.ps1')).replace('ID',identifier).replace('ORIGIN','https://localhost:'+str(server.server_port)).replace('SNAPSHOT',snapshot).replace('URL','https://must-not-be-contacted.invalid/private' if case=='wrong_url' else expected).replace('HASH',hashlib.sha256(content).hexdigest()).replace('SIZE',str(len(content))).replace('ROOT',str(tmp_path))
    wrapper=tmp_path/'run.ps1';wrapper.write_text(script,encoding='utf-8-sig')
    trust=tmp_path/'trust';trust.mkdir()
    try:
        result=subprocess.run([PWSH,'-NoProfile','-File',str(wrapper)],env={**os.environ,'SSL_CERT_FILE':str(certificate),'SSL_CERT_DIR':str(trust)},capture_output=True,text=True,timeout=30)
    finally:server.shutdown();server.server_close();thread.join(timeout=5)
    assert result.returncode==0,result.stderr
    outcome=json.loads((tmp_path/'out.json').read_text(encoding='utf-8-sig'))
    if case=='success':
        assert outcome['status']=='success',outcome
        assert (tmp_path/'cache.zip').read_bytes()==content
    else:
        assert outcome['status']=='failed',outcome
        assert not (tmp_path/'cache.zip').exists()
    assert not (tmp_path/'cache.zip.partial').exists()
    assert calls==([] if case=='wrong_url' else [(expected,'Bearer fixture-private-token')])
