"""Veille des versions stables Windows, sans modification des images de production."""
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from html.parser import HTMLParser
import json
import re
import threading
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from fastapi import Depends

SOURCE = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
DOWNLOAD = 'https://www.microsoft.com/software-download/windows11'
MAX_PAGE = 2 * 1024 * 1024


def timestamp():
    return datetime.now(timezone.utc).isoformat()


class ReleaseTables(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables, self.rows, self.row, self.cell = [], None, None, None

    def handle_starttag(self, tag, attrs):
        if tag == 'table': self.rows = []
        elif tag == 'tr' and self.rows is not None: self.row = []
        elif tag in ('td', 'th') and self.row is not None: self.cell = []

    def handle_data(self, data):
        if self.cell is not None: self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ('td', 'th') and self.cell is not None:
            self.row.append(' '.join(' '.join(self.cell).split()))
            self.cell = None
        elif tag == 'tr' and self.row is not None:
            self.rows.append(self.row)
            self.row = None
        elif tag == 'table' and self.rows is not None:
            self.tables.append(self.rows)
            self.rows = None


def release_key(value):
    year, half = re.fullmatch(r'(\d{2})H([12])', value).groups()
    return int(year), int(half)


def parse_releases(html, today=None):
    parser = ReleaseTables()
    parser.feed(html)
    today = today or date.today()
    found = {}
    for table in parser.tables:
        if not table: continue
        header = [c.lower() for c in table[0]]
        required = ('version', 'servicing option', 'availability date', 'os build')
        if not all(name in header for name in required): continue
        indexes = {name: header.index(name) for name in required}
        end_index = next((i for i, name in enumerate(header) if 'end of servicing' in name and 'home' in name), None)
        for row in table[1:]:
            if len(row) <= max(indexes.values()): continue
            version = row[indexes['version']].strip()
            channel = row[indexes['servicing option']].lower()
            published = row[indexes['availability date']]
            build = row[indexes['os build']]
            if not re.fullmatch(r'\d{2}H[12]', version): continue
            if channel != 'general availability channel': continue
            if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', published): continue
            if not re.fullmatch(r'\d{5}(?:\.\d+)?', build): continue
            if date.fromisoformat(published) > today: continue
            end = row[end_index] if end_index is not None and len(row) > end_index else None
            found[version] = {'family':'11', 'release':version, 'build':build,
                              'available_at':published, 'home_pro_end':end}
    if not found:
        raise ValueError('Le tableau Microsoft des versions stables est absent ou son format a changé. Aucune nouvelle version confirmée.')
    return sorted(found.values(), key=lambda item:release_key(item['release']), reverse=True)


class OfficialRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urlsplit(newurl)
        if parts.scheme != 'https' or parts.hostname != 'learn.microsoft.com' or parts.port not in (None, 443):
            raise ValueError('Redirection de la source Microsoft refusée.')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_releases():
    opener = build_opener(OfficialRedirect())
    with opener.open(Request(SOURCE, headers={'User-Agent':'AtelierPXE-WindowsVersions/1.0'}), timeout=25) as response:
        raw = response.read(MAX_PAGE + 1)
    if len(raw) > MAX_PAGE: raise ValueError('Page Microsoft trop volumineuse.')
    return parse_releases(raw.decode('utf-8-sig', errors='strict'))


class WindowsReleases:
    def __init__(self, db, contexts):
        self.db, self.contexts = db, contexts
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix='atelier-windows-versions')
        with db(write=True) as con:
            con.execute('''CREATE TABLE IF NOT EXISTS windows_release_check (
                id INTEGER PRIMARY KEY CHECK(id=1), status TEXT NOT NULL,
                checked_at TEXT, success_at TEXT, message TEXT NOT NULL, releases_json TEXT NOT NULL)''')
            con.execute("INSERT OR IGNORE INTO windows_release_check VALUES (1,'not_checked',NULL,NULL,?, '[]')",
                        ('La vérification Microsoft des nouvelles versions n’a pas encore été lancée.',))
            con.execute("UPDATE windows_release_check SET status='failed',message=? WHERE status='running'",
                        ('Vérification interrompue par le redémarrage de la console. Relancer la recherche.',))

    def public(self):
        with self.db() as con:
            record = dict(con.execute('SELECT * FROM windows_release_check WHERE id=1').fetchone())
        versions = json.loads(record.pop('releases_json'))
        known = sorted({c.release for c in self.contexts() if c.family == '11'}, key=release_key, reverse=True)
        newer = [v['release'] for v in versions if known and release_key(v['release']) > release_key(known[0])]
        return {**record, 'releases':versions, 'known_releases':known, 'newer_releases':newer,
                'comparison':'unknown' if not known else 'new_version' if newer else 'current',
                'source_url':SOURCE, 'download_url':DOWNLOAD}

    def queue(self):
        if not self.lock.acquire(blocking=False): return self.public()
        try:
            with self.db(write=True) as con:
                con.execute("UPDATE windows_release_check SET status='running',checked_at=?,message=? WHERE id=1",
                            (timestamp(), 'Consultation des versions stables publiées par Microsoft.'))
            self.pool.submit(self.check)
        except Exception:
            self.lock.release()
            raise
        return self.public()

    def check(self):
        try:
            releases = fetch_releases()
            with self.db(write=True) as con:
                con.execute("UPDATE windows_release_check SET status='completed',success_at=?,message=?,releases_json=? WHERE id=1",
                            (timestamp(), 'Versions stables vérifiées auprès de Microsoft. Aucune image de production modifiée.', json.dumps(releases, ensure_ascii=False)))
        except Exception:
            with self.db(write=True) as con:
                con.execute("UPDATE windows_release_check SET status='failed',message=? WHERE id=1",
                            ('Vérification Microsoft impossible : accès réseau indisponible ou format de publication modifié. Les derniers résultats sont conservés et peuvent être anciens.',))
        finally:
            self.lock.release()

    def routes(self, api, admin):
        api.state.windows_releases = self

        @api.get('/api/maintenance/windows/releases', dependencies=[Depends(admin)])
        def overview():
            return self.public()

        @api.post('/api/maintenance/windows/releases/refresh', dependencies=[Depends(admin)])
        def refresh():
            return self.queue()
