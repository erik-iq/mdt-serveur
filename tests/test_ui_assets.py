"""The HTML and each CSS/JS/logo update must have matching asset identities."""
import hashlib
import re
from pathlib import Path

from test_api import system

ROOT=Path(__file__).resolve().parents[1]


def test_ui_versions_assets_and_prevents_reuse_of_cached_html_and_css(system):
    client,_=system
    response=client.get('/')
    assert response.status_code==200 and response.headers['cache-control']=='no-store'
    for filename in ('style.css','app.js','maintenance.js','brand-logo.png'):
        path=ROOT/'app'/'static'/filename
        url='/static/'+filename+'?v='+hashlib.sha256(path.read_bytes()).hexdigest()[:16]
        assert '"'+url+'"' in response.text
        asset=client.get(url)
        assert asset.status_code==200 and asset.content==path.read_bytes()
        assert asset.headers['cache-control']=='no-store'
    assert re.search(r'<img[^>]+width="40" height="40"',response.text)
