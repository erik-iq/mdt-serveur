"""Veille Microsoft, notifications et conservation des résultats en cas d’échec."""
from datetime import date
import json
import threading
import time
from urllib.request import Request

import pytest
from app.windows_releases import OfficialRedirect, parse_releases, release_error
from urllib.error import HTTPError, URLError
import socket
import ssl
from test_api import auth, system
from app.windows_kb import KbContext

HTML='''<table><tr><th>Version</th><th>Servicing option</th><th>Availability date</th><th>OS build</th><th>End of servicing: Home and Pro</th></tr>
<tr><td><a>27H2</a></td><td>General Availability Channel</td><td>2027-10-01</td><td>28000.1</td><td>2029-10-01</td></tr>
<tr><td>26H2</td><td>General Availability Channel</td><td>2026-09-01</td><td>26300.1</td><td>2028-09-01</td></tr>
<tr><td>28H2</td><td>Insider Preview</td><td>2026-10-01</td><td>29000.1</td><td></td></tr>
<tr><td>25H2</td><td>General Availability Channel</td><td>2025-09-30</td><td>26200.1</td><td>2027-09-30</td></tr></table>'''


def wait(client):
    for _ in range(100):
        value=client.get('/api/maintenance/windows/releases',headers=auth()).json()
        if value['status']!='running': return value
        time.sleep(.01)
    pytest.fail('Vérification simulée toujours active')


def test_official_table_excludes_insider_and_future_and_rejects_changed_format():
    value=parse_releases(HTML,date(2026,10,22))
    assert [v['release'] for v in value]==['26H2','25H2']
    assert value[0]['home_pro_end']=='2028-09-01'
    assert parse_releases(HTML,date(2027,10,2))[0]['release']=='27H2'
    with pytest.raises(ValueError):parse_releases('<table><tr><th>Unrelated</th></tr></table>')
    with pytest.raises(ValueError):parse_releases(HTML.replace('General Availability Channel','Insider Preview'))


@pytest.mark.parametrize('target',['http://learn.microsoft.com/test','https://evil.test/test','https://learn.microsoft.com:444/test'])
def test_redirect_cannot_leave_official_https(target):
    with pytest.raises(ValueError):
        OfficialRedirect().redirect_request(Request('https://learn.microsoft.com/start'),None,302,'',{},target)


def test_refresh_auth_alert_and_preserved_results_on_network_failure(system,monkeypatch):
    client,data=system
    checker=client.app.state.windows_releases
    checker.contexts=lambda:[KbContext(family='11',release='25H2',architecture='x64',build=26200)]
    calls=[]
    def fetch():
        calls.append(1)
        return parse_releases(HTML,date(2026,10,22))
    monkeypatch.setattr('app.windows_releases.fetch_releases',fetch)
    route='/api/maintenance/windows/releases'
    assert client.get(route).status_code==401
    assert client.post(route+'/refresh').status_code==401
    assert client.get(route,headers=auth()).json()['status']=='not_checked'
    assert not calls
    assert client.post(route+'/refresh',headers=auth()).status_code==200
    value=wait(client)
    assert value['status']=='completed' and value['newer_releases']==['26H2']
    assert value['known_releases']==['25H2'] and value['comparison']=='new_version'
    saved=value['success_at']
    def failed():raise OSError('Private network details')
    monkeypatch.setattr('app.windows_releases.fetch_releases',failed)
    client.post(route+'/refresh',headers=auth())
    value=wait(client)
    assert value['status']=='failed' and value['success_at']==saved and len(value['releases'])==2
    assert 'Private network' not in json.dumps(value)
    checker.contexts=lambda:[]
    value=client.get(route,headers=auth()).json()
    assert value['comparison']=='unknown' and value['newer_releases']==[]
    checker.contexts=lambda:[KbContext(family='11',release='27H2',architecture='x64',build=28000)]
    assert client.get(route,headers=auth()).json()['comparison']=='current'
    assert calls==[1]
    assert not list(data.rglob('*.wim'))


def test_concurrent_refresh_only_one_request_and_restart_marks_interrupted(system,monkeypatch):
    client,data=system
    checker=client.app.state.windows_releases
    from app.windows_releases import WindowsReleases
    entered=threading.Event();release=threading.Event();calls=[]
    def fetch():
        calls.append(1);entered.set();release.wait(5)
        return parse_releases(HTML,date(2026,10,22))
    monkeypatch.setattr('app.windows_releases.fetch_releases',fetch)
    try:
        checker.queue();assert entered.wait(2)
        assert checker.queue()['status']=='running'
        assert calls==[1]
    finally:release.set()
    wait(client)
    with checker.db(write=True) as con:
        con.execute("UPDATE windows_release_check SET status='running'")
    restarted=WindowsReleases(checker.db,checker.contexts)
    result=restarted.public()
    assert result['status']=='failed' and result['releases']
    restarted.pool.shutdown()


def test_current_microsoft_headers_read_latest_build_and_end_of_updates():
    # En-têtes vérifiés dans Microsoft Release Health le 22 octobre 2026.
    html="""<table><thead><tr><th>Version</th><th>Servicing option</th><th>Availability date</th>
    <th>End of updates: Home, Pro, Pro Education, and Pro for Workstations</th>
    <th>End of updates: Enterprise, Education, IoT Enterprise, and Enterprise multi-session</th>
    <th>Latest update</th><th>Latest revision date</th><th>Latest build</th></tr></thead><tbody>
    <tr><td>26H2</td><td>General Availability Channel</td><td>2026-09-29</td><td>2028-10-10</td><td>2029-10-09</td>
    <td><a href="https://support.microsoft.com/">2026-10 B</a></td><td>2026-10-13</td><td>26300.9711</td></tr>
    <tr><td>25H2</td><td>General Availability Channel</td><td>2025-09-30</td><td>2027-10-12</td><td>2028-10-10</td>
    <td>2026-10 B</td><td>2026-10-13</td><td>26200.9711</td></tr></tbody></table>"""
    value=parse_releases(html,date(2026,10,22))
    assert [v['release'] for v in value]==['26H2','25H2']
    assert value[0]['build']=='26300.9711'
    assert value[0]['home_pro_end']=='2028-10-10'
    assert value[1]['home_pro_end']=='2027-10-12'


@pytest.mark.parametrize('exc,expected',[
    (HTTPError('https://learn.microsoft.com/',403,'private response',{},None),'HTTP 403'),
    (URLError(socket.gaierror('private DNS details')),'DNS'),
    (URLError(ssl.SSLCertVerificationError('private certificate details')),'certificat'),
    (TimeoutError('private timeout details'),'délai'),
    (ValueError('private format details'),'format'),
    (OSError('private network details'),'connexion réseau'),
])
def test_failure_message_distinguishes_cause_without_publishing_exception(exc,expected):
    message=release_error(exc)
    assert expected.lower() in message.lower()
    assert 'private' not in message
    assert 'derniers résultats sont conservés' in message
