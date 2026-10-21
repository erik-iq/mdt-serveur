"""Microsoft catalog parsing, checkpoints, payload integrity and fail-closed selection."""
from datetime import date
import hashlib
from io import BytesIO
from pathlib import Path
from urllib.parse import parse_qs
from urllib.request import Request
import json

import pytest

from scripts import windows_update_catalog as catalog

ID = '11111111-2222-4333-8444-555555555555'
TITLE = '2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5127648) (26300.9711)'
TODAY = date(2026, 10, 20)


def row(**changes):
    return dict({'id': ID, 'title': TITLE, 'classification': 'Security Updates', 'date': '10/13/2026'}, **changes)


def html(records, more=False):
    return '<input type="hidden" name="__VIEWSTATE" value="a&amp;b"><input type="hidden" name="__EVENTVALIDATION" value="ok">' + ''.join(
        f'<tr><td></td><td><a id="{item["id"]}_link">{item["title"]}</a></td><td>Windows 11</td><td>{item["classification"]}</td><td>{item["date"]}</td><td>n/a</td><td>size</td></tr>' for item in records
    ) + ("<a id=\"ctl00_catalogBody_nextPageLinkText\" href=\"javascript:__doPostBack('next','')\">Next</a>" if more else '')


def test_catalog_html_entities_and_all_pages(monkeypatch):
    pages = [html([row()], more=True), html([row(id='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')])]
    calls = []
    def fetch(opener, url, fields=None):
        calls.append(fields)
        return pages.pop(0)
    monkeypatch.setattr(catalog, 'fetch_page', fetch)
    result = catalog.search(None, 'Windows 11 26H2 x64')
    assert len(result) == 2
    assert calls[1]['__VIEWSTATE'] == 'a&b'
    assert calls[1]['__EVENTTARGET'] == 'ctl00$catalogBody$nextPageLinkText'
    monkeypatch.setattr(catalog, 'fetch_page', lambda *args: html([row()], more=True))
    with pytest.raises(ValueError, match='pagination'):
        catalog.search(None, 'query')


@pytest.mark.parametrize('title', [TITLE.replace('x64', 'arm64'), TITLE.replace('26H2', '25H2'),
    TITLE.replace('Cumulative Update', 'Cumulative Update Preview'), TITLE.replace('Windows 11', 'Windows Server 11'),
    TITLE.replace('Cumulative Update', 'Dynamic Cumulative Update'), TITLE.replace('Windows 11', 'Windows Insider 11')])
def test_never_substitute_another_release_architecture_or_preview(title):
    with pytest.raises(ValueError, match='Aucun correctif'):
        catalog.select_update([row(title=title)], '11', '26H2', 'x64', 'os', today=TODAY)


def test_latest_stable_and_matching_net_framework_only():
    old = row(date='09/08/2026', title=TITLE.replace('KB5127648', 'KB5111111'))
    future = row(date='11/10/2026')
    result = catalog.select_update([old, row(), future], '11', '26H2', 'x64', 'os', today=TODAY)
    assert result['kb'] == 'KB5127648' and result['target_build'] == '26300.9711'
    net = row(title='2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 26H2 for x64 (KB5127694)')
    assert catalog.select_update([row(), net], '11', '26H2', 'x64', 'net', today=TODAY)['kb'] == 'KB5127694'
    with pytest.raises(ValueError):
        catalog.select_update([net], '11', '26H2', 'x64', 'net', dotnet='4.8', today=TODAY)
    with pytest.raises(ValueError, match='Plusieurs'):
        catalog.select_update([row(), row(id='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', title=TITLE.replace('KB5127648', 'KB5111111'))], '11', '26H2', 'x64', 'os', today=TODAY)


@pytest.mark.parametrize('url', ['https://evil.test/a.msu', 'https://download.windowsupdate.com.evil.test/a.msu',
    'https://user:pass@download.windowsupdate.com/a.msu', 'https://download.windowsupdate.com:8443/a.msu',
    'https://download.windowsupdate.com/no-hash.msu', 'https://download.windowsupdate.com/a_'+'a'*40+'.exe'])
def test_unknown_hosts_and_non_msu_payloads_rejected(url):
    with pytest.raises(ValueError):
        catalog.download_links(f"downloadInformation[0].files[0].url = '{url}';")


class Response(BytesIO):
    def __init__(self, body, url):
        super().__init__(body)
        self.url = url


@pytest.mark.parametrize('host', ['download.windowsupdate.com', 'catalog.sf.dl.delivery.mp.microsoft.com'])
def test_download_hash_verification_reuse_repair_and_partial_cleanup(tmp_path, host):
    content = b'trusted fixture payload'
    name = 'windows11.0-kb5127648-x64_' + hashlib.sha256(content).hexdigest() + '.msu'
    item = catalog.download_links("downloadInformation[0].files[0].url = 'http://" + host + "/" + name + "';")[0]
    class Opener:
        count = 0
        def open(self, request, timeout):
            self.count += 1
            assert request.full_url.startswith('https://')
            return Response(content, request.full_url)
    opener = Opener()
    first = catalog.download(opener, item, tmp_path)
    assert catalog.download(opener, item, tmp_path) == first and opener.count == 1
    Path(first['path']).write_bytes(b'corrupt')
    catalog.download(opener, item, tmp_path)
    assert opener.count == 2
    bad = dict(item, expected_hash='0'*64, filename='bad_'+'0'*64+'.msu')
    with pytest.raises(ValueError, match='Empreinte'):
        catalog.download(opener, bad, tmp_path)
    assert not list(tmp_path.glob('*.partial')) and not (tmp_path / bad['filename']).exists()


def test_catalog_delivery_url_and_redirect_remain_scoped_to_microsoft():
    url = ('https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/'
           'c1521a9e-28f5-4040-8a13-b8df59c3b2a8/public/'
           'windows11.0-kb5127694-x64-ndp481_a1a6f6d3c61e46a77278881fc5f7245bcf09ce3f.msu')
    item, = catalog.download_links("downloadInformation[0].files[0].url = '" + url + "';")
    assert item['url'] == url
    assert item['algorithm'] == 'sha1'
    assert item['expected_hash'] == 'a1a6f6d3c61e46a77278881fc5f7245bcf09ce3f'
    redirect = catalog.MicrosoftRedirect()
    request = Request('https://download.windowsupdate.com/update.msu')
    assert redirect.redirect_request(request, None, 302, 'Found', {}, url).full_url == url
    for unsafe in (url.replace('.com/', '.com.evil.test/'),
                   url.replace('https://', 'http://'),
                   url.replace('https://', 'https://user:password@'),
                   url.replace('.com/', '.com:8443/')):
        with pytest.raises(ValueError, match='non autorisee'):
            redirect.redirect_request(request, None, 302, 'Found', {}, unsafe)
    with pytest.raises(ValueError, match='non autorisee'):
        catalog.safe_url(url, catalog=True)


def test_prepare_downloads_every_checkpoint_in_isolated_directory(tmp_path, monkeypatch):
    contents = {kb: kb.encode() for kb in ['KB5127648', 'KB5043080', 'KB5127694']}
    def link(kb):
        return f"https://download.windowsupdate.com/windows11.0-{kb.lower()}-x64_{hashlib.sha1(contents[kb]).hexdigest()}.msu"
    net = row(title='2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 26H2 for x64 (KB5127694)', id='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')
    monkeypatch.setattr(catalog, 'search', lambda *args: [row(), net])
    class Opener:
        def open(self, request, timeout):
            if request.data:
                update = json.loads(parse_qs(request.data.decode())['updateIDs'][0])[0]['updateID']
                kbs = ['KB5043080', 'KB5127648'] if update == ID else ['KB5127694']
                body = '\n'.join(f"downloadInformation[0].files[{i}].url = '{link(kb)}';" for i, kb in enumerate(kbs)).encode()
            else:
                kb = next(kb for kb in contents if kb.lower() in request.full_url)
                body = contents[kb]
            return Response(body, request.full_url)
    plan = catalog.prepare('11', '26H2', 'x64', '4.8.1', tmp_path, Opener())
    assert [len(group['files']) for group in plan['groups']] == [1, 2]
    assert [group['kind'] for group in plan['groups']] == ['net', 'os']
    assert 'kb5127648' in plan['groups'][1]['target_path']
    assert len({Path(file['path']).parent for file in plan['groups'][1]['files']}) == 1
    assert Path(plan['groups'][0]['target_path']).parent != Path(plan['groups'][1]['target_path']).parent
