"""Téléchargement des correctifs mensuels Windows/.NET depuis le catalogue Microsoft.

Aucun module tiers ou service non documenté n’est installé. Le catalogue HTML
n’est pas une API stable : refuser son changement de structure ou de téléchargement.
DISM reste responsable de l’applicabilité et de la validation des signatures."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from html import unescape
from html.parser import HTMLParser
import http.cookiejar
import json
from pathlib import Path
import re
import time
from urllib.parse import urlencode, urlsplit, unquote
from urllib.request import HTTPCookieProcessor, HTTPRedirectHandler, Request, build_opener
import uuid

CATALOG = 'https://www.catalog.update.microsoft.com'
GUID = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
DOWNLOAD_HOSTS = {'download.windowsupdate.com', 'catalog.s.download.windowsupdate.com',
                  'download.microsoft.com', 'catalog.sf.dl.delivery.mp.microsoft.com'}


def safe_url(url, catalog=False):
    parts = urlsplit(url)
    hosts = {'www.catalog.update.microsoft.com', 'catalog.update.microsoft.com'} if catalog else DOWNLOAD_HOSTS
    if (parts.scheme != 'https' or parts.hostname not in hosts or parts.username or
            parts.password or parts.port not in (None, 443) or parts.fragment):
        raise ValueError('Adresse Microsoft non autorisée : ' + url)
    return url


class MicrosoftRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        safe_url(newurl, catalog=urlsplit(req.full_url).hostname.endswith('catalog.update.microsoft.com'))
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class CatalogPage(HTMLParser):
    def __init__(self, body):
        super().__init__()
        self.rows, self.hidden = [], {}
        self.next_page = False
        self._row, self._cell, self._id = None, None, None
        self.feed(body)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'input' and attrs.get('type', '').lower() == 'hidden' and attrs.get('name'):
            self.hidden[attrs['name']] = attrs.get('value', '')
        if tag == 'a' and attrs.get('id', '').endswith('nextPageLinkText'):
            self.next_page = 'doPostBack' in attrs.get('href', '') and 'disabled' not in attrs
        if tag == 'tr':
            self._row, self._id = [], None
        if self._row is not None:
            if tag == 'td':
                self._cell = []
            if tag == 'a' and re.fullmatch(GUID + r'_link', attrs.get('id', '')):
                self._id = attrs['id'][:-5]

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag):
        if tag == 'td' and self._row is not None and self._cell is not None:
            self._row.append(' '.join(' '.join(self._cell).split()))
            self._cell = None
        if tag == 'tr' and self._row is not None:
            if self._id:
                if len(self._row) < 6:
                    raise ValueError('Colonnes du catalogue Microsoft inconnues')
                self.rows.append({'id': str(uuid.UUID(self._id)), 'title': self._row[1],
                                  'classification': self._row[3], 'date': self._row[4]})
            self._row, self._cell = None, None


def fetch_page(opener, url, fields=None):
    safe_url(url, catalog=True)
    request = Request(url, data=urlencode(fields).encode() if fields is not None else None,
                      headers={'User-Agent': 'AtelierPXE-WimMaintenance/1.0', 'Accept-Language': 'en-US'})
    with opener.open(request, timeout=90) as response:
        safe_url(response.url, catalog=True)
        body = response.read(8 * 1024 * 1024 + 1)
    if len(body) > 8 * 1024 * 1024:
        raise ValueError('Réponse catalogue trop grande')
    return body.decode('utf-8-sig')


def search(opener, query):
    url = CATALOG + '/Search.aspx?' + urlencode({'q': query})
    page = CatalogPage(fetch_page(opener, url))
    rows, seen = [], set()
    for _ in range(30):
        ids = tuple(row['id'] for row in page.rows)
        if not ids or ids in seen:
            raise ValueError('Catalogue vide, inaccessible ou pagination inconnue : ' + query)
        seen.add(ids)
        rows.extend(page.rows)
        if not page.next_page:
            return rows
        if '__VIEWSTATE' not in page.hidden or '__EVENTVALIDATION' not in page.hidden:
            raise ValueError('État de pagination Microsoft absent')
        page = CatalogPage(fetch_page(opener, url, dict(page.hidden,
            __EVENTTARGET='ctl00$catalogBody$nextPageLinkText', __EVENTARGUMENT='')))
    raise ValueError('Trop de pages Microsoft ; affiner la recherche')


def select_update(rows, family, release, arch, kind, dotnet='4.8.1', today=None):
    if family not in ('10', '11') or not re.fullmatch(r'\d{2}H[12]', release) or arch not in ('x64', 'arm64'):
        raise ValueError('Version Windows ou architecture non prise en charge')
    candidates = []
    for row in rows:
        title = row['title']
        if not re.search(r'Windows\s+' + family + r',?\s+(?:version\s+)?' + release + r'\b', title, re.I):
            continue
        if not re.search(r'\b' + arch + r'\b', title, re.I) or re.search(r'preview|insider|dynamic|enablement|server', title, re.I):
            continue
        if row['classification'].lower() not in ('security updates', 'critical updates', 'updates'):
            continue
        if not re.search(r'cumulative update', title, re.I) or bool(re.search(r'\.NET Framework', title, re.I)) != (kind == 'net'):
            continue
        if kind == 'net' and not re.search(r'(?<!\d)' + re.escape(dotnet) + r'(?![.\d])', title):
            continue
        if kind == 'os' and row['classification'].lower() != 'security updates':
            continue
        kb = re.search(r'\bKB\d{6,8}\b', title, re.I)
        if not kb:
            continue
        date = datetime.strptime(row['date'], '%m/%d/%Y').date()
        if date > (today or datetime.now(timezone.utc).date()):
            continue
        build = re.search(r'\((\d{5})\.(\d+)\)', title)
        candidates.append(dict(row, kb=kb[0].upper(), published=date.isoformat(), kind=kind,
                               target_build=build[0][1:-1] if build else None))
    if not candidates:
        raise ValueError('Aucun correctif cumulatif stable compatible trouve : ' + kind)
    candidates.sort(key=lambda row: (row['published'], tuple(map(int, (row['target_build'] or '0.0').split('.')))), reverse=True)
    latest = candidates[0]
    if any(item['published'] == latest['published'] and item['id'] != latest['id']
           and item['kb'] != latest['kb'] for item in candidates[1:]):
        raise ValueError('Plusieurs correctifs différents à la même date ; sélection manuelle nécessaire')
    return latest


def download_links(body):
    matches = re.findall(r"downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*['\"]([^'\"]+)['\"]", body)
    if not matches:
        raise ValueError('Liens MSU Microsoft absents')
    result = []
    for raw in matches:
        url = unescape(raw).replace(r'\/', '/').replace(r'\u0026', '&')
        if url.startswith('http://'):
            url = 'https://' + url[7:]
        safe_url(url)
        filename = unquote(urlsplit(url).path.rsplit('/', 1)[-1])
        match = re.fullmatch(r'([A-Za-z0-9._-]+)_([0-9a-fA-F]{40}|[0-9a-fA-F]{64})\.msu', filename)
        if not match:
            raise ValueError('Paquet Microsoft sans empreinte MSU connue : ' + filename)
        result.append({'url': url, 'filename': filename, 'expected_hash': match[2].lower(),
                       'algorithm': 'sha1' if len(match[2]) == 40 else 'sha256'})
    return list({item['filename']: item for item in result}.values())


def checksum(path, algorithm='sha256'):
    result = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def download(opener, item, directory):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / item['filename']
    if any(item.is_symlink() or (hasattr(item, 'is_junction') and item.is_junction())
           for item in [path, *path.parents]):
        raise ValueError('Cache lie interdit')
    if not path.is_file() or checksum(path, item['algorithm']) != item['expected_hash']:
        partial = path.with_suffix('.partial')
        if partial.is_symlink():
            raise ValueError('Fichier temporaire lie interdit')
        try:
            safe_url(item['url'])
            with opener.open(Request(item['url'], headers={'User-Agent': 'AtelierPXE-WimMaintenance/1.0'}), timeout=180) as response, partial.open('wb') as output:
                safe_url(response.url)
                total = 0
                while block := response.read(1024 * 1024):
                    total += len(block)
                    if total > 12 * 1024 ** 3:
                        raise ValueError('Paquet Microsoft trop grand')
                    output.write(block)
            if checksum(partial, item['algorithm']) != item['expected_hash']:
                raise ValueError('Empreinte Microsoft incorrecte : ' + item['filename'])
            partial.replace(path)
        finally:
            partial.unlink(missing_ok=True)
    return dict(item, path=str(path.resolve()), sha256=checksum(path), size=path.stat().st_size)


class DeadlineOpener:
    """Borner la recherche des métadonnées sans modifier les contrôles des téléchargements ou redirections."""
    def __init__(self, opener, seconds):
        self.opener, self.deadline = opener, time.monotonic() + seconds

    def open(self, request, timeout):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Délai maximal de recherche du catalogue Microsoft atteint')
        return self.opener.open(request, timeout=min(timeout, remaining))


def select_plan(family, release, arch, dotnet, opener=None, timeout_seconds=180):
    opener = opener or build_opener(HTTPCookieProcessor(http.cookiejar.CookieJar()), MicrosoftRedirect())
    opener = DeadlineOpener(opener, timeout_seconds)
    groups = []
    # Terminer par le cumulatif Windows, après la mise à jour du composant .NET.
    for kind in ('net', 'os') if dotnet else ('os',):
        query = f'Windows {family} {release} {arch} Cumulative Update'
        if kind == 'net':
            query += ' .NET Framework ' + dotnet
        groups.append(select_update(search(opener, query), family, release, arch, kind, dotnet=dotnet))
    return {'family': family, 'release': release, 'architecture': arch, 'dotnet': dotnet,
            'created_at': datetime.now(timezone.utc).isoformat(), 'groups': groups}


def prepare(family, release, arch, dotnet, cache, opener=None, on_progress=None):
    opener = opener or build_opener(HTTPCookieProcessor(http.cookiejar.CookieJar()), MicrosoftRedirect())
    plan = select_plan(family, release, arch, dotnet, opener)
    groups = []
    for selected in plan['groups']:
        if on_progress: on_progress('Téléchargement ou vérification du cache : ' + selected['kb'] + ' : ' + selected['title'])
        fields = {'updateIDs': json.dumps([{'size': 0, 'updateID': selected['id'], 'uidInfo': selected['id']}])}
        links = download_links(fetch_page(opener, CATALOG + '/DownloadDialog.aspx', fields))
        if any(not re.search(r'[-_]' + arch + r'[-_]', item['filename'], re.I) for item in links):
            raise ValueError('Architecture du téléchargement incohérente')
        target = [item for item in links if re.search(r'\b' + selected['kb'] + r'[-_]', item['filename'], re.I)]
        if len(target) != 1:
            raise ValueError('Paquet cible Microsoft absent ou ambigu')
        # Garder la cible et tous ses checkpoints ensemble, sans MSU étrangers.
        directory = Path(cache) / selected['id']
        allowed = {item['filename'] for item in links}
        if directory.exists() and any(path.name not in allowed for path in directory.glob('*.msu')):
            raise ValueError('Le dossier checkpoint contient un MSU inattendu')
        files = [download(opener, item, directory) for item in links]
        groups.append(dict(selected, files=files,
                           target_path=next(item['path'] for item in files if item['filename'] == target[0]['filename'])))
    return dict(plan, groups=groups)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('family', 'release', 'arch', 'cache', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--dotnet', default='4.8.1', choices=['4.8', '4.8.1', 'none'])
    parser.add_argument('--select-only', action='store_true', help='Check current KBs without downloading packages')
    args = parser.parse_args()
    dotnet = '' if args.dotnet == 'none' else args.dotnet
    plan = (select_plan(args.family, args.release, args.arch, dotnet) if args.select_only
            else prepare(args.family, args.release, args.arch, dotnet, args.cache))
    output = Path(args.output)
    output.write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding='utf-8')
    print(str(output))


if __name__ == '__main__':
    main()
