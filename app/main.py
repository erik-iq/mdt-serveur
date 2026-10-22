"""Contrôle du déploiement Windows. Le réseau local fournit le transport PXE."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator, model_validator

from app.customization import ApplicationInput, BootConnection, BootDiscovery, BundleInput, OPTIONS, Personalization, WizardSelection, defaults_for_locale
from app.windows_secrets import read_share_credentials
from app.reports import ComputerReport, WindowsProgress, make_pdf, report_lines
from app.software_jobs import SoftwareJobs, BundleApplications
from app.inventories import Inventories, MAX_INVENTORY
from app.computers import computer_routes
from app.hp_repository import HpRepository
from app.maintenance import Maintenance
from app.windows_kb import WindowsKbRepository
from app.windows_releases import WindowsReleases
from app.identity import normalize_serial, migrate_identity, public_machine, insert_machine, match_machine

ROOT = Path(__file__).resolve().parent.parent
BOOT_KINDS = {"wimboot", "bcd", "sdi", "winpe"}
TERMINAL = {"staged", "failed", "cancelled"}


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def file_hash(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


class MachineInput(BaseModel):
    hostname: str = Field(pattern=r"^[A-Za-z][A-Za-z0-9-]{0,14}$")
    mac: str = ''
    serial_number: str = Field(default='', max_length=80)
    description: str = Field(default="", max_length=240)

    @field_validator("mac")
    @classmethod
    def validate_mac(cls, value):
        if not value:return value
        value = value.replace("-", ":").upper()
        if not re.fullmatch(r"[0-9A-F]{2}(:[0-9A-F]{2}){5}", value):
            raise ValueError("Adresse MAC invalide")
        if int(value[:2], 16) & 1 or value == "00:00:00:00:00:00":
            raise ValueError("Une adresse MAC unicast est nécessaire")
        return value


    @field_validator('serial_number')
    @classmethod
    def serial(cls,value):
        return normalize_serial(value) if value else ''

    @model_validator(mode='after')
    def identity_present(self):
        if not self.serial_number and not self.mac:raise ValueError('Numéro de série requis')
        return self


class AssetInput(BaseModel):
    filename: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,120}$")
    kind: str = Field(pattern=r"^(wimboot|bcd|sdi|winpe|windows|application|wallpaper)$")


class ProfileInput(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    asset_id: str
    image_index: int = Field(default=1, ge=1, le=100)
    locale: str = Field(default="fr-FR", pattern=r"^[a-z]{2}-[A-Z]{2}$")
    windows_version: str = Field(default='', max_length=24)
    edition: str = Field(default='', max_length=40)
    settings: Personalization | None = None


class DeploymentInput(BaseModel):
    machine_id: str
    profile_id: str
    disk_number: int = Field(default=0, ge=0, le=32)
    confirmation: str = ''
    wizard_enabled: bool = False


class EventInput(BaseModel):
    status: str = Field(pattern=r"^(running|staged|failed)$")
    progress: int = Field(ge=0, le=100)
    message: str = Field(min_length=1, max_length=1000)


def create_app(data_dir=None, admin_token=None, base_url=None, internal_mode=None, automatic_windows=None, client_software=None, auto_enroll=None):
    internal = internal_mode if internal_mode is not None else os.getenv('MDT_INTERNAL_MODE', '') == '1'
    automatic = automatic_windows if automatic_windows is not None else os.getenv('MDT_AUTOMATIC_WINDOWS', '') == '1'
    client_apps = client_software if client_software is not None else os.getenv('MDT_CLIENT_SOFTWARE', '') == '1'
    enrollment = auto_enroll if auto_enroll is not None else os.getenv('MDT_AUTO_ENROLL', '') == '1'
    if enrollment and not internal:
        raise ValueError('L’arrivée automatique WinPE exige le mode interne')
    data = Path(data_dir or os.getenv("MDT_DATA_DIR", ROOT / "data")).resolve()
    data.mkdir(parents=True, exist_ok=True)
    artifacts = data / "artifacts"
    artifacts.mkdir(exist_ok=True)
    token_file = data / "admin-token"
    token = admin_token or os.getenv("MDT_ADMIN_TOKEN")
    if not token:
        if not token_file.exists():
            descriptor = os.open(token_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(descriptor, "w") as handle:
                handle.write(secrets.token_urlsafe(32))
        token = token_file.read_text().strip()
    if len(token) < 24:
        raise ValueError("MDT_ADMIN_TOKEN doit contenir au moins 24 caractères")
    public_url = (base_url or os.getenv("MDT_BASE_URL", "http://127.0.0.1:8080")).rstrip("/")
    url = urlsplit(public_url)
    if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password or url.query or url.fragment or url.path:
        raise ValueError("MDT_BASE_URL doit être une origine HTTP(S), sans chemin ni identifiants")
    if any(c in public_url for c in "\r\n\t '\""):
        raise ValueError("MDT_BASE_URL contient des caractères non autorisés")
    db_path = data / "deployment.sqlite3"

    @contextmanager
    def db(write=False):
        con = sqlite3.connect(db_path, timeout=20)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA foreign_keys=ON")
        try:
            con.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield con
            con.commit()
        except Exception:
            con.rollback()
            raise
        finally:
            con.close()

    with db(write=True) as con:
        con.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS machines (
                id TEXT PRIMARY KEY, hostname TEXT NOT NULL UNIQUE COLLATE NOCASE,
                mac TEXT NOT NULL UNIQUE, description TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY, filename TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                sha256 TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
                created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS profiles (
                id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
                asset_id TEXT NOT NULL REFERENCES assets(id), image_index INTEGER NOT NULL,
                locale TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS windows_image_candidates (
                run_id TEXT PRIMARY KEY, source_asset_id TEXT NOT NULL REFERENCES assets(id),
                asset_id TEXT NOT NULL UNIQUE REFERENCES assets(id), source_sha256 TEXT NOT NULL,
                status TEXT NOT NULL, mappings_json TEXT NOT NULL, created_at TEXT NOT NULL, published_at TEXT);
            CREATE TABLE IF NOT EXISTS windows_image_test_profiles (
                profile_id TEXT PRIMARY KEY REFERENCES profiles(id), run_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS deployments (
                id TEXT PRIMARY KEY, machine_id TEXT NOT NULL REFERENCES machines(id),
                profile_id TEXT NOT NULL REFERENCES profiles(id), disk_number INTEGER NOT NULL,
                token_hash TEXT NOT NULL, status TEXT NOT NULL, progress INTEGER NOT NULL,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS active_machine ON deployments(machine_id)
                WHERE status IN ('queued','running');
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, deployment_id TEXT NOT NULL REFERENCES deployments(id),
                status TEXT NOT NULL, progress INTEGER NOT NULL, message TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS applications (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL,
                asset_id TEXT NOT NULL REFERENCES assets(id), arguments TEXT NOT NULL,
                entry_point TEXT NOT NULL, install_mode TEXT NOT NULL, manufacturer TEXT NOT NULL,
                created_at TEXT NOT NULL, UNIQUE(name,version));
            CREATE TABLE IF NOT EXISTS bundles (
                id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, description TEXT NOT NULL,
                application_ids_json TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS computer_reports (
                deployment_id TEXT PRIMARY KEY REFERENCES deployments(id),
                report_json TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS events_deployment ON events(deployment_id,id);
        """)

        # Les migrations additives préservent la console installée sur DEPLOY-01.
        additions = {
            'profiles': {'windows_version': "TEXT NOT NULL DEFAULT ''", 'edition': "TEXT NOT NULL DEFAULT ''",
                         'settings_json': "TEXT NOT NULL DEFAULT '{}'", 'archived': 'INTEGER NOT NULL DEFAULT 0'},
            'deployments': {'wizard_enabled': 'INTEGER NOT NULL DEFAULT 0',
                            'catalog_json': "TEXT NOT NULL DEFAULT '{}'", 'selection_json': "TEXT NOT NULL DEFAULT '{}'",
                            'boot_code_hash': 'TEXT', 'boot_code_expires': 'TEXT',
                            'report_token_hash': 'TEXT', 'report_expires': 'TEXT',
                            'windows_status': 'TEXT', 'windows_progress': 'INTEGER',
                            'windows_message': 'TEXT', 'windows_updated_at': 'TEXT'},
        }
        for table, columns in additions.items():
            present = {r['name'] for r in con.execute(f'PRAGMA table_info({table})')}
            for name, definition in columns.items():
                if name not in present:
                    con.execute(f'ALTER TABLE {table} ADD COLUMN {name} {definition}')
        migrate_identity(con)
        # Retirer les profils unilingues du catalogue sans perdre leurs historiques.
        con.execute("UPDATE profiles SET archived=1 WHERE edition IN ('Famille unilingue','CoreSingleLanguage')")
        tests = {r['profile_id'] for r in con.execute('SELECT profile_id FROM windows_image_test_profiles')}
        for profile in con.execute('SELECT id,name FROM profiles WHERE archived=0').fetchall():
            if profile['id'] in tests:
                continue
            name = re.sub(r'\s*[-\u2013\u2014|:]\s*Test\s*$', '', profile['name'], flags=re.I).strip()
            if name != profile['name'] and name and not con.execute('SELECT 1 FROM profiles WHERE name=?', (name,)).fetchone():
                con.execute('UPDATE profiles SET name=? WHERE id=?', (name, profile['id']))
        con.execute('CREATE UNIQUE INDEX IF NOT EXISTS boot_code_unique ON deployments(boot_code_hash) WHERE boot_code_hash IS NOT NULL')

    api = FastAPI(title="Atelier PXE", version="0.2.0", docs_url=None, redoc_url=None, openapi_url=None)
    api.state.data_dir = data
    # Une nouvelle URL à chaque changement empêche les anciens CSS/JS de modifier le nouvel HTML.
    static_root = ROOT / 'app' / 'static'
    index_html = (static_root / 'index.html').read_text(encoding='utf-8')
    ui_assets = {}
    for filename in ('style.css', 'app.js', 'maintenance.js', 'brand-logo.png'):
        version = file_hash(static_root / filename)[:16]
        original = '/static/' + filename
        ui_assets[filename] = original + '?v=' + version
        index_html = index_html.replace('"' + original + '"', '"' + ui_assets[filename] + '"')

    @api.middleware("http")
    async def security_headers(request: Request, call_next):
        if request.url.path.startswith('/api/windows/') and request.method == 'POST':
            # Borner le flux ainsi que Content-Length, qui peut être absent.
            limit = MAX_INVENTORY if '/inventory/' in request.url.path else 128 * 1024
            body = bytearray()
            async for chunk in request.stream():
                body.extend(chunk)
                if len(body) > limit:
                    return PlainTextResponse('Rapport trop volumineux', status_code=413)
            request._body = bytes(body)
        response = await call_next(request)
        if response.headers.get('content-type', '').startswith('application/json'):
            # Sinon, Windows PowerShell 5.1 devine une ancienne page de codes.
            response.headers['Content-Type'] = 'application/json; charset=utf-8'
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        if request.url.path == '/' or request.url.path.startswith(("/api", "/boot", "/static/")):
            response.headers["Cache-Control"] = "no-store"
        return response

    def admin(request: Request, authorization: str = Header(default="")):
        if internal:
            if request.headers.get('sec-fetch-site') == 'cross-site' or request.headers.get('origin', public_url) != public_url:
                raise HTTPException(403, 'Origine externe refusée')
            return
        if not hmac.compare_digest(authorization.encode(), ("Bearer " + token).encode()):
            raise HTTPException(401, "Jeton administrateur requis")

    inventories = Inventories(data, db)
    software = SoftwareJobs(api, db, data, admin, ROOT / 'scripts' / 'software-sources.json')
    hp_repository = HpRepository(data, db)

    def row(con, table, identifier):
        record = con.execute(f"SELECT * FROM {table} WHERE id=?", (identifier,)).fetchone()
        if not record:
            raise HTTPException(404, "Ressource introuvable")
        return dict(record)

    def asset_path(asset):
        path = artifacts / asset["filename"]
        if path.is_symlink() or not path.is_file() or path.resolve().parent != artifacts.resolve():
            raise HTTPException(409, "Fichier absent ou chemin non autorisé")
        stat = path.stat()
        if stat.st_size != asset["size"] or stat.st_mtime_ns != asset["mtime_ns"]:
            raise HTTPException(409, "Fichier modifie : enregistrez une nouvelle image sous un autre nom")
        return path

    def profile_public(record, con):
        result = dict(record)
        saved = json.loads(result.pop('settings_json'))
        result['settings'] = Personalization.model_validate(saved or defaults_for_locale(result['locale'])).model_dump()
        if internal:
            result['settings'].update(user_locale='fr-CH', keyboard='100c:0000100c', timezone='W. Europe Standard Time', registered_owner='', organization='')
            if not result['settings']['wallpaper_asset_id']:
                for wallpaper in con.execute("SELECT * FROM assets WHERE kind='wallpaper' ORDER BY created_at DESC"):
                    if re.sub(r'[ _-]','',wallpaper['filename']).lower() in {'fondatelier.png','fonatelier.png'}:
                        try: asset_path(wallpaper)
                        except HTTPException: continue
                        result['settings']['wallpaper_asset_id']=wallpaper['id']
                        break
        if client_apps:
            result['settings'].update(software_mode='winget', central_inventory=True, application_ids=[], bundle_ids=[])
        if automatic:
            result['settings']['unattended']=True
        result['settings'].update(windows_update=False, store_update=False)
        return result

    def bundle_public(record):
        result = dict(record)
        result['application_ids'] = json.loads(result.pop('application_ids_json'))
        return result

    def asset_snapshot(con, identifier, kind):
        value = row(con, 'assets', identifier)
        if value['kind'] != kind:
            raise HTTPException(400, f'Type de fichier requis : {kind}')
        asset_path(value)
        return {k: value[k] for k in ('id', 'filename', 'kind', 'sha256', 'size')}

    def resolved_settings(con, settings):
        settings = Personalization.model_validate(settings).model_dump()
        settings.update(windows_update=False, store_update=False)
        if client_apps:
            settings.update(software_mode='winget', central_inventory=True, application_ids=[], bundle_ids=[])
        ids = [] if settings['software_mode'] == 'winget' else list(settings['application_ids'])
        for identifier in ([] if settings['software_mode'] == 'winget' else settings['bundle_ids']):
            bundle = bundle_public(row(con, 'bundles', identifier))
            ids.extend(bundle['application_ids'])
        apps = []
        for identifier in dict.fromkeys(ids):
            application = row(con, 'applications', identifier)
            application['asset'] = asset_snapshot(con, application['asset_id'], 'application')
            apps.append(application)
        wallpaper = asset_snapshot(con, settings['wallpaper_asset_id'], 'wallpaper') if settings['wallpaper_asset_id'] else None
        return {'settings': settings, 'applications': apps, 'wallpaper': wallpaper}

    def client_portable_tools(con):
        # HP Image Assistant est installé par WinGet dans Windows. Aucun ZIP
        # ni bundle côté serveur n’est nécessaire pour un nouveau déploiement.
        return []

    def catalogue(con, profile_id, interactive):
        profile_rows = con.execute('SELECT * FROM profiles WHERE archived=0 ORDER BY name').fetchall() if interactive else [row(con, 'profiles', profile_id)]
        profiles = []
        for record in profile_rows:
            profile = profile_public(record, con)
            profile['asset'] = asset_snapshot(con, profile['asset_id'], 'windows')
            resolved_settings(con, profile['settings'])
            profiles.append(profile)
        if not interactive:
            selected = resolved_settings(con, profiles[0]['settings'])
            selected_bundles = [bundle_public(row(con, 'bundles', i)) for i in profiles[0]['settings']['bundle_ids']]
            return {'profiles': profiles, 'applications': selected['applications'], 'bundles': selected_bundles,
                    'wallpapers': [selected['wallpaper']] if selected['wallpaper'] else [], 'options': OPTIONS, 'tools': client_portable_tools(con)}
        apps = [] if client_apps else [dict(r) for r in con.execute('SELECT * FROM applications ORDER BY name,version')]
        for app in apps:
            app['asset'] = asset_snapshot(con, app['asset_id'], 'application')
        bundles = [] if client_apps else [bundle_public(r) for r in con.execute('SELECT * FROM bundles ORDER BY name')]
        wallpapers = [asset_snapshot(con, r['id'], 'wallpaper') for r in con.execute("SELECT id FROM assets WHERE kind='wallpaper'")]
        return {'profiles': profiles, 'applications': apps, 'bundles': bundles, 'wallpapers': wallpapers, 'options': OPTIONS, 'tools': client_portable_tools(con)}

    def job_selection(con, job):
        selected = json.loads(job['selection_json'])
        machine = row(con, 'machines', job['machine_id'])
        if not selected:
            profile = profile_public(row(con, 'profiles', job['profile_id']), con)
            selected = {'profile_id': profile['id'], 'hostname': machine['hostname'], 'settings': profile['settings']}
        profile = profile_public(row(con, 'profiles', selected['profile_id']), con)
        resolved = resolved_settings(con, selected['settings'])
        return selected, profile, machine, resolved

    def plan_data(con, job):
        selected, profile, machine, resolved = job_selection(con, job)
        asset = asset_snapshot(con, profile['asset_id'], 'windows')
        return {'id': job['id'], 'status': job['status'], 'hostname': selected['hostname'],
                'inventory_hostname': machine['hostname'], 'serial_number': machine['serial_number'], 'mac': machine['mac'], 'disk_number': job['disk_number'],
                'profile_id': profile['id'], 'profile_name': profile['name'], 'windows_version': profile['windows_version'],
                'edition': profile['edition'], 'image_index': profile['image_index'], 'locale': profile['locale'],
                'image_filename': asset['filename'], 'image_size': asset['size'], 'image_sha256': asset['sha256'],
                'image_path': f"/api/agent/{job['id']}/image", 'wizard_enabled': bool(job['wizard_enabled']), 'internal_mode': bool(internal),
                'tools': json.loads(job['catalog_json']).get('tools', []) if client_apps else [], **resolved}

    def agent(con, identifier, authorization):
        job = row(con, "deployments", identifier)
        supplied = authorization.removeprefix("Bearer ") if authorization.startswith("Bearer ") else ""
        if not hmac.compare_digest(digest(supplied), job["token_hash"]):
            raise HTTPException(401, "Jeton de déploiement invalide")
        if job["status"] in TERMINAL:
            raise HTTPException(409, "Déploiement termine ou annule")
        return job

    def event(con, identifier, status, progress, message):
        con.execute("INSERT INTO events(deployment_id,status,progress,message,created_at) VALUES (?,?,?,?,?)",
                    (identifier, status, progress, message, now()))

    @api.get("/health")
    def health():
        with db() as con:
            con.execute("SELECT 1").fetchone()
        return {"status": "ok", "version": "0.2.0", "release": "ATELIER-2", "revision": "4.0", "ui_revision": "IQ-5.8.1"}

    @api.get('/api/session')
    def session_options():
        return {'internal_mode': bool(internal), 'automatic_windows': bool(automatic), **({'auto_enroll': True} if enrollment else {}), **({'client_software': True} if client_apps else {})}

    @api.get("/api/state", dependencies=[Depends(admin)])
    def state():
        with db() as con:
            result = {name: [dict(r) for r in con.execute(f"SELECT * FROM {name} ORDER BY created_at DESC")]
                      for name in ("machines", "assets", "applications")}
            result['machines']=[public_machine(m) for m in result['machines']]
            validations = {r['asset_id']: r['status'] for r in con.execute('SELECT asset_id,status FROM windows_image_candidates')}
            for asset in result['assets']:
                asset['image_validation'] = validations.get(asset['id'])
            result['profiles'] = [profile_public(r, con) for r in con.execute('SELECT * FROM profiles WHERE archived=0 ORDER BY created_at DESC')]
            image_tests = {r['profile_id'] for r in con.execute('SELECT profile_id FROM windows_image_test_profiles')}
            for profile in result['profiles']:
                profile['image_test'] = profile['id'] in image_tests
            result['bundles'] = [bundle_public(r) for r in con.execute('SELECT * FROM bundles ORDER BY created_at DESC')]
            result["deployments"] = [dict(r) for r in con.execute("""SELECT d.id,d.machine_id,d.profile_id,d.disk_number,d.status,
                d.progress,d.created_at,d.updated_at,d.selection_json,d.wizard_enabled,m.hostname,m.mac,m.serial_number,p.name AS profile_name,
                d.windows_status,d.windows_progress,d.windows_message,d.windows_updated_at,
                EXISTS(SELECT 1 FROM computer_reports r WHERE r.deployment_id=d.id) AS has_report,
                EXISTS(SELECT 1 FROM inventory_files i WHERE i.deployment_id=d.id) AS has_inventory,
                EXISTS(SELECT 1 FROM inventory_files i WHERE i.deployment_id=d.id AND i.kind='hp_summary') AS has_hp_summary
                FROM deployments d JOIN machines m ON m.id=d.machine_id JOIN profiles p ON p.id=d.profile_id
                ORDER BY d.created_at DESC LIMIT 100""")]
            for item in result['deployments']:
                selection = json.loads(item.pop('selection_json'))
                item['hostname'] = selection.get('hostname', item['hostname'])
            result['reports'] = [dict(r) for r in con.execute('''SELECT r.deployment_id,r.created_at,d.machine_id,
                d.windows_status,json_extract(r.report_json,'$.hostname') AS hostname
                FROM computer_reports r JOIN deployments d ON d.id=r.deployment_id ORDER BY r.created_at DESC LIMIT 100''')]
            # Le parcours WinGet du poste ne dépend pas de l’interface d’un agent serveur.
            result['software_sync'] = None if client_apps else software.state(con)
            result['hp_repository'] = hp_repository.state(con)
            result["totals"] = {"active": con.execute("SELECT COUNT(*) FROM deployments WHERE status IN ('queued','running')").fetchone()[0],
                                "staged": con.execute("SELECT COUNT(*) FROM deployments WHERE status='staged'").fetchone()[0]}
        result["boot_ready"] = BOOT_KINDS <= {a["kind"] for a in result["assets"]}
        result["base_url"] = public_url
        result['customization_options'] = OPTIONS
        result['internal_mode'] = bool(internal)
        result['automatic_windows'] = bool(automatic)
        result['auto_enroll'] = bool(enrollment)
        result['client_software'] = bool(client_apps)
        return result

    @api.post("/api/machines", status_code=201, dependencies=[Depends(admin)])
    def add_machine(body: MachineInput):
        identifier = str(uuid.uuid4())
        try:
            with db(write=True) as con:
                if not body.serial_number and con.execute('SELECT 1 FROM machines WHERE mac=?',(body.mac,)).fetchone():
                    raise HTTPException(409,'Cette MAC est déjà connue ; utiliser le numéro de série du poste')
                insert_machine(con,identifier,body.hostname,body.mac,body.description,now(),body.serial_number)
                return public_machine(row(con, "machines", identifier))
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Le nom ou le numéro de série existe déjà")

    @api.post("/api/assets", status_code=201, dependencies=[Depends(admin)])
    def add_asset(body: AssetInput, request: Request):
        path = artifacts / body.filename
        if path.is_symlink() or not path.is_file() or path.resolve().parent != artifacts.resolve():
            raise HTTPException(400, "Déposez le fichier dans data/artifacts, sans lien symbolique")
        if body.kind in {"windows", "winpe"}:
            if path.suffix.lower() != ".wim":
                raise HTTPException(400, "L’image doit porter l’extension .wim")
            with path.open("rb") as handle:
                if handle.read(8) != b"MSWIM\x00\x00\x00":
                    raise HTTPException(400, "Une image WIM non fractionnee est requise")
        if body.kind == 'application' and path.suffix.lower() not in {'.exe', '.msi', '.zip'}:
            raise HTTPException(400, 'Un installateur .exe/.msi ou un bundle .zip est requis')
        if body.kind == 'wallpaper':
            with path.open('rb') as handle:
                signature = handle.read(8)
            if not ((path.suffix.lower() == '.png' and signature == b'\x89PNG\r\n\x1a\n')
                    or (path.suffix.lower() in {'.jpg', '.jpeg'} and signature.startswith(b'\xff\xd8\xff'))):
                raise HTTPException(400, 'Une image PNG ou JPEG est requise')
        stat_before = path.stat()
        checksum = file_hash(path)
        stat = path.stat()
        if stat.st_mtime_ns != stat_before.st_mtime_ns or stat.st_size != stat_before.st_size:
            raise HTTPException(409, "Le fichier est en cours de modification")
        identifier = str(uuid.uuid4())
        try:
            with db(write=True) as con:
                if body.kind == 'application':
                    software.mutation(con, request)
                con.execute("INSERT INTO assets VALUES (?,?,?,?,?,?,?)", (identifier, body.filename, body.kind, checksum, stat.st_size, stat.st_mtime_ns, now()))
                return row(con, "assets", identifier)
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Ce fichier est déjà enregistré")

    @api.post("/api/profiles", status_code=201, dependencies=[Depends(admin)])
    def add_profile(body: ProfileInput):
        identifier = str(uuid.uuid4())
        try:
            with db(write=True) as con:
                asset = row(con, "assets", body.asset_id)
                if asset["kind"] != "windows":
                    raise HTTPException(400, "Le profil nécessite une image Windows")
                if con.execute("SELECT 1 FROM windows_image_candidates WHERE asset_id=? AND status!='published'", (asset['id'],)).fetchone():
                    raise HTTPException(409, 'Image en validation : utiliser les profils TEST fournis, puis publier après les tests')
                asset_path(asset)
                settings = body.settings.model_dump() if body.settings else defaults_for_locale(body.locale)
                resolved_settings(con, settings)
                con.execute("INSERT INTO profiles(id,name,asset_id,image_index,locale,created_at,windows_version,edition,settings_json) VALUES (?,?,?,?,?,?,?,?,?)",
                            (identifier, body.name, body.asset_id, body.image_index, body.locale, now(), body.windows_version,
                             body.edition, json.dumps(settings, ensure_ascii=False)))
                return profile_public(row(con, "profiles", identifier), con)
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Ce nom de profil existe déjà")

    def validate_application_asset(con, body):
        asset = asset_snapshot(con, body.asset_id, 'application')
        if asset['filename'].lower().endswith('.zip'):
            if not body.entry_point:
                raise HTTPException(400, 'Le point d’entrée du ZIP est requis')
        elif body.entry_point or body.install_mode == 'portable':
            raise HTTPException(400, 'Le point d’entrée et le mode portable sont réservés aux ZIP')
        if body.install_mode == 'portable' and body.arguments:
            raise HTTPException(400, 'Omettre les arguments en mode portable ; Atelier gere les paramètres HP Image Assistant')

    @api.put('/api/applications/{identifier}', dependencies=[Depends(admin)])
    def update_application(identifier: str, body: ApplicationInput, request: Request):
        try:
            with db(write=True) as con:
                software.mutation(con, request)
                row(con, 'applications', identifier)
                if con.execute("SELECT 1 FROM deployments WHERE status IN ('queued','running') LIMIT 1").fetchone():
                    raise HTTPException(409, 'Terminer ou annuler les autorisations WinPE actives avant de remplacer un logiciel')
                validate_application_asset(con, body)
                con.execute('UPDATE applications SET name=?,version=?,asset_id=?,arguments=?,entry_point=?,install_mode=?,manufacturer=? WHERE id=?',
                            (body.name, body.version, body.asset_id, body.arguments, body.entry_point, body.install_mode, body.manufacturer, identifier))
                return row(con, 'applications', identifier)
        except sqlite3.IntegrityError:
            raise HTTPException(409, 'Ce logiciel et cette version existent déjà')

    @api.post('/api/applications', status_code=201, dependencies=[Depends(admin)])
    def add_application(body: ApplicationInput, request: Request):
        identifier = str(uuid.uuid4())
        try:
            with db(write=True) as con:
                software.mutation(con, request)
                validate_application_asset(con, body)
                con.execute('INSERT INTO applications VALUES (?,?,?,?,?,?,?,?,?)',
                            (identifier, body.name, body.version, body.asset_id, body.arguments, body.entry_point,
                             body.install_mode, body.manufacturer, now()))
                return row(con, 'applications', identifier)
        except sqlite3.IntegrityError:
            raise HTTPException(409, 'Ce logiciel et cette version existent déjà')

    @api.post('/api/bundles', status_code=201, dependencies=[Depends(admin)])
    def add_bundle(body: BundleInput):
        identifier = str(uuid.uuid4())
        try:
            with db(write=True) as con:
                for app_id in body.application_ids:
                    application = row(con, 'applications', app_id)
                    asset_snapshot(con, application['asset_id'], 'application')
                con.execute('INSERT INTO bundles VALUES (?,?,?,?,?)',
                            (identifier, body.name, body.description, json.dumps(body.application_ids), now()))
                return bundle_public(row(con, 'bundles', identifier))
        except sqlite3.IntegrityError:
            raise HTTPException(409, 'Ce nom de bundle existe déjà')

    @api.post('/api/bundles/{identifier}/applications', dependencies=[Depends(admin)])
    def append_bundle(identifier: str, body: BundleApplications, request: Request):
        with db(write=True) as con:
            software.mutation(con, request)
            software.no_deployments(con)
            bundle = bundle_public(row(con, 'bundles', identifier))
            identifiers = list(dict.fromkeys(bundle['application_ids'] + [str(i) for i in body.application_ids]))
            if len(identifiers) > 50:
                raise HTTPException(400, 'Un bundle accepte au maximum 50 logiciels')
            for app_id in identifiers:
                application = row(con, 'applications', app_id)
                asset_snapshot(con, application['asset_id'], 'application')
            con.execute('UPDATE bundles SET application_ids_json=? WHERE id=?', (json.dumps(identifiers), identifier))
            return bundle_public(row(con, 'bundles', identifier))

    @api.post("/api/deployments", status_code=201, dependencies=[Depends(admin)])
    def deploy(body: DeploymentInput):
        identifier, agent_token = str(uuid.uuid4()), secrets.token_urlsafe(32)
        boot_code = ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(20)) if body.wizard_enabled and not internal else None
        try:
            with db(write=True) as con:
                if not client_apps:
                    software.no_active(con)
                machine = row(con, "machines", body.machine_id)
                profile = profile_public(row(con, "profiles", body.profile_id), con)
                asset_path(row(con, "assets", profile["asset_id"]))
                if not internal and body.confirmation != "EFFACER " + machine["hostname"]:
                    raise HTTPException(400, "Confirmation d’effacement incorrecte")
                timestamp = now()
                catalog = catalogue(con, body.profile_id, body.wizard_enabled)
                selection = {'profile_id': profile['id'], 'hostname': machine['hostname'], 'settings': profile['settings']}
                con.execute("INSERT INTO deployments(id,machine_id,profile_id,disk_number,token_hash,status,progress,created_at,updated_at,wizard_enabled,catalog_json,selection_json,boot_code_hash,boot_code_expires) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            (identifier, body.machine_id, body.profile_id, body.disk_number, digest(agent_token), 'queued', 0,
                             timestamp, timestamp, int(body.wizard_enabled), json.dumps(catalog), json.dumps(selection),
                             digest(boot_code) if boot_code else None, (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat() if body.wizard_enabled else None))
                event(con, identifier, "queued", 0, "Déploiement autorise ; attente de l’agent WinPE")
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Un déploiement est déjà actif sur cette machine")
        return {"id": identifier, "agent_token": agent_token, "base_url": public_url,
                'boot_code': '-'.join(boot_code[i:i+4] for i in range(0, 20, 4)) if boot_code else None}

    @api.post('/api/boot/discover')
    def boot_discover(body: BootDiscovery, request: Request):
        if not internal:
            raise HTTPException(403, 'Connexion automatique désactivée')
        if body.reinstall_deployment_id and (not enrollment or not body.serial_number):
            raise HTTPException(403, 'La réinstallation exige l’arrivée automatique et le numéro de série du poste')
        if request.headers.get('sec-fetch-site') == 'cross-site' or request.headers.get('origin', public_url) != public_url:
            raise HTTPException(403, 'Origine externe refusée')
        if enrollment and body.release != 'ATELIER-4':
            raise HTTPException(409, 'Démarrer sur la nouvelle image ATELIER-4 ; cette ancienne version WinPE ne prépare pas les logiciels et inventaires du nouveau parcours')
        try:
            macs = list(dict.fromkeys(MachineInput.validate_mac(value) for value in body.macs))
        except ValueError as exc:
            raise HTTPException(422, 'Adresse MAC unicast invalide') from exc
        with db(write=True) as con:
            try:machine=match_machine(con,body.serial_number,macs)
            except ValueError as exc:raise HTTPException(409,str(exc)) from exc
            if machine and macs:
                con.execute('UPDATE machines SET mac=? WHERE id=?',(macs[0],machine['id']))
                machine['mac']=macs[0]
            records=[dict(r) for r in con.execute("SELECT * FROM deployments WHERE machine_id=? AND status IN ('queued','running')",(machine['id'],))] if machine else []
            if len(records) > 1 or any(r['status'] == 'running' for r in records):
                raise HTTPException(409, 'Un déploiement est déjà actif ou plusieurs postes correspondent')
            if body.reinstall_deployment_id and (not machine or records):
                raise HTTPException(409, 'Demande de réinstallation obsolète ; reconnecter le poste sans forcer une nouvelle installation')
            valid = [r for r in records if (enrollment or r['wizard_enabled']) and (enrollment or (r['boot_code_expires'] or '') > now())]
            if not valid and enrollment:
                if records:
                    raise HTTPException(409, 'Annuler la demande manuelle existante avant une arrivée automatique')
                known=bool(machine)
                if machine:
                    latest = con.execute('SELECT * FROM deployments WHERE machine_id=? ORDER BY created_at DESC LIMIT 1', (machine['id'],)).fetchone()
                    if body.reinstall_deployment_id:
                        if not latest or latest['id'] != str(body.reinstall_deployment_id) or latest['status'] != 'staged':
                            raise HTTPException(409, 'Cette ancienne installation ne correspond plus au dernier essai du poste')
                    elif latest and latest['status'] == 'staged' and latest['windows_status'] not in {'completed', 'failed', 'needs_attention'}:
                        raise HTTPException(409, detail={'code':'windows_prepared',
                            'message':'Windows est déjà préparé. Démarrer sur le disque local pour terminer, ou choisir une nouvelle installation dans WinPE.',
                            'deployment_id':latest['id'],'serial_number':machine['serial_number'] or ''})
                else:
                    identifier=str(uuid.uuid4())
                    hostname=('PC-'+uuid.uuid4().hex[:12].upper()) if body.serial_number else ('PC-'+macs[0].replace(':',''))
                    machine={'id':identifier,'hostname':hostname,'mac':macs[0] if macs else '', 'serial_number':body.serial_number or None}
                profiles = [profile_public(r, con) for r in con.execute("SELECT * FROM profiles WHERE archived=0 AND id NOT IN (SELECT profile_id FROM windows_image_test_profiles) ORDER BY CASE WHEN edition IN ('Pro','Professional') THEN 0 ELSE 1 END,name")]
                if not profiles:
                    raise HTTPException(409, 'Aucun profil Windows disponible ; synchroniser les éditions sur le serveur')
                profile = profiles[0]
                catalog = catalogue(con, profile['id'], True)
                if not known:
                    insert_machine(con,machine['id'],machine['hostname'],machine['mac'],'Arrivée automatique WinPE',now(),body.serial_number)
                identifier, timestamp = str(uuid.uuid4()), now()
                selection = {'profile_id': profile['id'], 'hostname': machine['hostname'], 'settings': profile['settings']}
                con.execute("""INSERT INTO deployments(id,machine_id,profile_id,disk_number,token_hash,status,progress,created_at,updated_at,wizard_enabled,catalog_json,selection_json,boot_code_expires)
                    VALUES (?,?,?,0,?,'queued',0,?,?,1,?,?,?)""",
                    (identifier, machine['id'], profile['id'], digest(secrets.token_urlsafe(32)), timestamp, timestamp,
                     json.dumps(catalog), json.dumps(selection), (datetime.now(timezone.utc)+timedelta(hours=2)).isoformat()))
                event(con, identifier, 'queued', 0, 'Poste detecte automatiquement ; attente du choix Windows et de la confirmation locale du disque')
                if body.reinstall_deployment_id:
                    event(con, identifier, 'queued', 0, 'Nouvelle installation demandée dans WinPE après image appliquée : '+str(body.reinstall_deployment_id)+'. Confirmation du disque encore requise.')
                valid = [row(con, 'deployments', identifier)]
            if len(valid) != 1:
                raise HTTPException(409, 'Créer une autorisation pour ce numéro de série ou activer l’arrivée automatique WinPE')
            job, new_token = valid[0], secrets.token_urlsafe(32)
            if enrollment:
                refreshed = catalogue(con, job['profile_id'], True)
                con.execute('UPDATE deployments SET wizard_enabled=1,catalog_json=? WHERE id=?', (json.dumps(refreshed), job['id']))
                job = row(con, 'deployments', job['id'])
            con.execute('UPDATE deployments SET token_hash=?,updated_at=? WHERE id=?', (digest(new_token), now(), job['id']))
            return {'id': job['id'], 'agent_token': new_token, 'plan': plan_data(con, job), 'catalog': json.loads(job['catalog_json'])}

    @api.get('/api/agent/{identifier}/share-credentials')
    def share_credentials(identifier: str, authorization: str = Header(default='')):
        if not internal or url.scheme != 'https':
            raise HTTPException(403, 'Connexion automatique du partage réservée au mode interne HTTPS')
        with db() as con:
            agent(con, identifier, authorization)
        try:
            return read_share_credentials(data / 'internal-share.json')
        except Exception:
            raise HTTPException(503, 'Connexion du partage non préparée : exécutez Enable-InternalMode.ps1 sur le serveur') from None

    @api.post('/api/boot/connect')
    def boot_connect(body: BootConnection):
        code = body.code.replace('-', '').strip().upper()
        with db(write=True) as con:
            record = con.execute("SELECT * FROM deployments WHERE boot_code_hash=? AND status='queued' AND boot_code_expires>?", (digest(code), now())).fetchone()
            if not record:
                raise HTTPException(401, 'Code d’installation absent, expire ou déjà utilisé')
            job = dict(record)
            machine = row(con, 'machines', job['machine_id'])
            macs = {value.replace('-', ':').upper() for value in body.macs}
            serial=machine['serial_number']
            if (serial and serial!=body.serial_number) or (not serial and (body.serial_number or machine['mac'] not in macs)):
                raise HTTPException(403, 'Ce code est réservé à un autre poste')
            if serial and macs:con.execute('UPDATE machines SET mac=? WHERE id=?',(sorted(macs)[0],machine['id']))
            new_token = secrets.token_urlsafe(32)
            con.execute('UPDATE deployments SET token_hash=?,updated_at=? WHERE id=?', (digest(new_token), now(), job['id']))
            return {'id': job['id'], 'agent_token': new_token, 'plan': plan_data(con, job), 'catalog': json.loads(job['catalog_json'])}

    @api.post('/api/agent/{identifier}/configure')
    def configure(identifier: str, body: WizardSelection, authorization: str = Header(default='')):
        with db(write=True) as con:
            job = agent(con, identifier, authorization)
            if job['status'] != 'queued':
                raise HTTPException(409, 'Les paramètres sont figes après le début du déploiement')
            if not job['wizard_enabled']:
                raise HTTPException(403, 'Le choix dans l’assistant n’a pas été autorisé pour ce poste')
            catalog = json.loads(job['catalog_json'])
            if body.profile_id not in {p['id'] for p in catalog.get('profiles', [])}:
                raise HTTPException(403, 'Ce profil ne fait pas partie de l’autorisation')
            settings = body.settings.model_dump()
            settings.update(windows_update=False, store_update=False)
            allowed_apps = {a['id'] for a in catalog['applications']}
            allowed_bundles = {b['id'] for b in catalog['bundles']}
            allowed_wallpapers = {w['id'] for w in catalog['wallpapers']}
            if (not set(settings['application_ids']) <= allowed_apps or not set(settings['bundle_ids']) <= allowed_bundles
                    or (settings['wallpaper_asset_id'] and settings['wallpaper_asset_id'] not in allowed_wallpapers)):
                raise HTTPException(403, 'La sélection contient un élément non autorisé')
            duplicate = con.execute('SELECT id FROM machines WHERE hostname=? COLLATE NOCASE AND id!=?', (body.hostname, job['machine_id'])).fetchone()
            if duplicate:
                raise HTTPException(409, 'Ce nom est déjà réservé à un autre poste')
            for active in con.execute("SELECT id,selection_json FROM deployments WHERE status IN ('queued','running') AND id!=?", (identifier,)):
                if json.loads(active['selection_json']).get('hostname', '').lower() == body.hostname.lower():
                    raise HTTPException(409, 'Ce nom est déjà utilisé par un autre déploiement actif')
            resolved_settings(con, settings)
            if enrollment:
                con.execute('UPDATE machines SET hostname=? WHERE id=?', (body.hostname, job['machine_id']))
            selected = body.model_dump(exclude={'disk_number'})
            selected['settings']=settings
            con.execute('UPDATE deployments SET profile_id=?,selection_json=?,disk_number=?,updated_at=? WHERE id=?',
                        (body.profile_id, json.dumps(selected), body.disk_number if body.disk_number is not None else job['disk_number'], now(), identifier))
            event(con, identifier, 'queued', 0, f'Assistant : profil et parametres valides pour {body.hostname}')
            return plan_data(con, row(con, 'deployments', identifier))

    @api.get("/api/deployments/{identifier}/events", dependencies=[Depends(admin)])
    def events(identifier: str):
        with db() as con:
            row(con, "deployments", identifier)
            return [dict(r) for r in con.execute("SELECT * FROM events WHERE deployment_id=? ORDER BY id", (identifier,))]

    @api.post("/api/deployments/{identifier}/cancel", dependencies=[Depends(admin)])
    def cancel(identifier: str):
        with db(write=True) as con:
            job = row(con, "deployments", identifier)
            if job["status"] in TERMINAL:
                raise HTTPException(409, "Déploiement déjà terminé")
            con.execute("UPDATE deployments SET status='cancelled',updated_at=? WHERE id=?", (now(), identifier))
            event(con, identifier, "cancelled", job["progress"], "Annulation demandée ; un DISM déjà lancé ne peut pas être interrompu à distance")
        return {"status": "cancelled"}

    @api.get("/api/agent/{identifier}/plan")
    def plan(identifier: str, authorization: str = Header(default="")):
        with db() as con:
            job = agent(con, identifier, authorization)
            return plan_data(con, job)

    @api.get("/api/agent/{identifier}/image")
    def image(identifier: str, authorization: str = Header(default="")):
        with db() as con:
            job = agent(con, identifier, authorization)
            profile = row(con, "profiles", job["profile_id"])
            asset = row(con, "assets", profile["asset_id"])
            path = asset_path(asset)
        return FileResponse(path, media_type="application/octet-stream", filename=asset["filename"])

    @api.post("/api/agent/{identifier}/claim")
    def claim(identifier: str, authorization: str = Header(default="")):
        with db(write=True) as con:
            job = agent(con, identifier, authorization)
            if job["status"] != "queued":
                raise HTTPException(409, "Ce déploiement a déjà été pris en charge")
            plan_data(con, job)
            report_token = secrets.token_urlsafe(32)
            expires = (datetime.now(timezone.utc) + timedelta(days=14)).isoformat()
            con.execute("UPDATE deployments SET status='running',updated_at=?,boot_code_hash=NULL,report_token_hash=?,report_expires=? WHERE id=?", (now(), digest(report_token), expires, identifier))
            event(con, identifier, "running", 0, "L’agent WinPE a réservé le déploiement")
        return {"claimed": True, "report_token": report_token, "report_expires": expires}

    def windows_agent(con, identifier, authorization):
        job = row(con, 'deployments', identifier)
        supplied = authorization.removeprefix('Bearer ') if authorization.startswith('Bearer ') else ''
        if not job['report_token_hash'] or not hmac.compare_digest(digest(supplied), job['report_token_hash']):
            raise HTTPException(401, 'Jeton de rapport invalide')
        if not job['report_expires'] or job['report_expires'] < now():
            raise HTTPException(401, 'Jeton de rapport expire')
        if job['status'] not in {'running', 'staged'}:
            raise HTTPException(409, 'Rapport refuse pour ce déploiement')
        return job

    @api.get('/api/windows/{identifier}/tools/{asset_id}')
    def windows_tool(identifier: str, asset_id: str, authorization: str = Header(default='')):
        with db() as con:
            job = windows_agent(con, identifier, authorization)
            tools = json.loads(job['catalog_json']).get('tools', [])
            allowed = next((tool['asset'] for tool in tools if tool['asset']['id'] == asset_id), None)
            if not allowed:
                raise HTTPException(403, 'Outil absent de ce déploiement')
            asset = row(con, 'assets', asset_id)
            if asset['sha256'] != allowed['sha256']:
                raise HTTPException(409, 'Outil modifie depuis le démarrage')
            path = asset_path(asset)
        return FileResponse(path, media_type='application/octet-stream', filename=asset['filename'])

    inventories.routes(api, windows_agent, admin, now)
    hp_repository.routes(api, windows_agent, admin)
    Maintenance(data, db, hp_repository).routes(api, admin)
    kb_repository = WindowsKbRepository(data, db)
    kb_repository.routes(api, windows_agent, admin)
    WindowsReleases(db, kb_repository.contexts).routes(api, admin)
    computer_routes(api, db, admin, windows_agent, now)

    @api.post('/api/windows/{identifier}/progress')
    def windows_progress(identifier: str, body: WindowsProgress, authorization: str = Header(default='')):
        with db(write=True) as con:
            job = windows_agent(con, identifier, authorization)
            if job['windows_status'] in {'completed', 'failed', 'needs_attention'} and body.status != job['windows_status']:
                raise HTTPException(409, 'Préparation Windows déjà terminée')
            con.execute('UPDATE deployments SET windows_status=?,windows_progress=?,windows_message=?,windows_updated_at=? WHERE id=?',
                        (body.status, body.progress, body.message, now(), identifier))
        return {'accepted': True}

    @api.post('/api/windows/{identifier}/report')
    async def receive_computer_report(identifier: str, body: ComputerReport, request:Request, authorization: str = Header(default='')):
        snapshot = body.model_dump()
        report_hash=hashlib.sha256(await request.body()).hexdigest()
        if any(len(k) > 100 or len(v) > 2000 for k, v in body.inventory.items()) or any(len(w) > 1500 for w in body.warnings):
            raise HTTPException(422, 'Champ de rapport trop long')
        with db(write=True) as con:
            job = windows_agent(con, identifier, authorization)
            selected = json.loads(job['selection_json'])
            hostname = selected.get('hostname') or row(con, 'machines', job['machine_id'])['hostname']
            if body.hostname.lower() != hostname.lower():
                raise HTTPException(409, 'Nom différent du poste autorisé')
            if job['windows_status'] in {'completed', 'failed', 'needs_attention'} and body.status != job['windows_status']:
                raise HTTPException(409, 'État final différent du rapport précédent')
            con.execute('INSERT INTO computer_reports VALUES (?,?,?) ON CONFLICT(deployment_id) DO UPDATE SET report_json=excluded.report_json,created_at=excluded.created_at',
                        (identifier, json.dumps(snapshot, ensure_ascii=False), now()))
            con.execute('INSERT OR REPLACE INTO report_receipts VALUES (?,?)',(identifier,report_hash))
            con.execute('UPDATE deployments SET windows_status=?,windows_progress=?,windows_updated_at=? WHERE id=?',
                        (body.status, 100 if body.status == 'completed' else 90, now(), identifier))
        return {'accepted': True, 'pdf_path': f'/api/deployments/{identifier}/report.pdf','deployment_id':identifier,'sha256':report_hash}

    @api.get('/api/deployments/{identifier}/report.pdf', dependencies=[Depends(admin)])
    def download_computer_report(identifier: str):
        with db() as con:
            record = con.execute('SELECT report_json FROM computer_reports WHERE deployment_id=?', (identifier,)).fetchone()
            if not record:
                raise HTTPException(404, 'Rapport pas encore reçu')
            snapshot = json.loads(record['report_json'])
            entries = [dict(r) for r in con.execute('SELECT * FROM events WHERE deployment_id=? ORDER BY id', (identifier,))]
        return Response(make_pdf(report_lines(snapshot, entries)), media_type='application/pdf',
                        headers={'Content-Disposition': f'attachment; filename="Rapport-{snapshot["hostname"]}.pdf"'})

    @api.post("/api/agent/{identifier}/events")
    def report(identifier: str, body: EventInput, authorization: str = Header(default="")):
        with db(write=True) as con:
            job = agent(con, identifier, authorization)
            if job["status"] != "running" or body.progress < job["progress"] or (body.status == "staged" and body.progress != 100):
                raise HTTPException(409, "Transition ou progression invalide")
            con.execute("UPDATE deployments SET status=?,progress=?,updated_at=? WHERE id=?", (body.status, body.progress, now(), identifier))
            event(con, identifier, body.status, body.progress, body.message)
        return {"accepted": True}

    @api.get("/boot/menu.ipxe", response_class=PlainTextResponse)
    def boot_menu():
        with db() as con:
            assets = [dict(r) for r in con.execute("SELECT * FROM assets ORDER BY created_at DESC")]
        selected = {}
        for asset in assets:
            if asset["kind"] in BOOT_KINDS and asset["kind"] not in selected:
                selected[asset["kind"]] = asset
        if not BOOT_KINDS <= selected.keys():
            return PlainTextResponse("#!ipxe\necho WinPE indisponible : enregistrer wimboot, BCD, boot.sdi et boot.wim.\nsleep 10\nexit\n", status_code=503)
        for asset in selected.values():
            asset_path(asset)
        target = lambda kind: public_url + "/boot/assets/" + selected[kind]["id"]
        return "\n".join(["#!ipxe", "menu Atelier PXE - Installation Windows", "item local Démarrer sur le disque local", "item winpe Atelier de déploiement WinPE", "choose --default local --timeout 15000 target || exit", "goto ${target}", ":local", "exit", ":winpe", "imgfree", f"kernel {target('wimboot')}", f"initrd {target('bcd')} BCD", f"initrd {target('sdi')} boot.sdi", f"initrd {target('winpe')} boot.wim", "boot || goto failed", ":failed", "echo Échec du démarrage WinPE", "shell", ""])

    @api.get("/boot/assets/{identifier}")
    def boot_asset(identifier: str):
        with db() as con:
            asset = row(con, "assets", identifier)
            if asset["kind"] not in BOOT_KINDS:
                raise HTTPException(403, "Image d’installation protégée")
            path = asset_path(asset)
        return FileResponse(path, media_type="application/octet-stream")

    @api.get("/winpe/Deploy.ps1")
    def powershell():
        return FileResponse(ROOT / "scripts" / "Deploy.ps1", media_type="text/plain")

    @api.get("/")
    def index():
        return HTMLResponse(index_html)

    api.mount("/static", StaticFiles(directory=ROOT / "app" / "static"), name="static")
    return api
