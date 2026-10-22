"""Cache Microsoft sur le serveur et distribution limitée au déploiement demandeur."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import threading
import uuid

from fastapi import Depends, Header, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator
from typing import Literal

from scripts.windows_update_catalog import prepare


def now():
    return datetime.now(timezone.utc).isoformat()


class KbContext(BaseModel):
    model_config = ConfigDict(extra='forbid')
    family: Literal['10','11']
    release: str = Field(pattern=r'^\d{2}H[12]$')
    architecture: Literal['x64','arm64']
    dotnet: Literal['4.8','4.8.1','none'] = 'none'
    build: int = Field(ge=19041, le=99999)

    @model_validator(mode='after')
    def matching_family(self):
        if (self.build >= 22000) != (self.family == '11'):
            raise ValueError('Famille Windows incompatible avec le build')
        return self


class WindowsKbRepository:
    def __init__(self, data, db):
        self.data, self.db = data, db
        self.root = data/'windows-kb'
        self.root.mkdir(exist_ok=True)
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix='atelier-kb')
        self.futures = set()
        self.lock = threading.Lock()
        with db(write=True) as con:
            con.executescript('''
                CREATE TABLE IF NOT EXISTS windows_kb_jobs (
                    id TEXT PRIMARY KEY, context_json TEXT NOT NULL, context_key TEXT NOT NULL,
                    status TEXT NOT NULL, message TEXT NOT NULL, manifest_json TEXT,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE UNIQUE INDEX IF NOT EXISTS windows_kb_active ON windows_kb_jobs(context_key)
                    WHERE status IN ('queued','running');
                CREATE TABLE IF NOT EXISTS windows_kb_requests (
                    deployment_id TEXT PRIMARY KEY REFERENCES deployments(id),
                    job_id TEXT NOT NULL REFERENCES windows_kb_jobs(id));
            ''')
            # Un arrêt de la console ne laisse pas de téléchargement fantôme.
            con.execute("UPDATE windows_kb_jobs SET status='failed',message=?,updated_at=? WHERE status IN ('queued','running')",
                        ('Téléchargement interrompu par le redémarrage de la console ; relancer la préparation.', now()))

    def checked(self, path):
        path = Path(path)
        if not path.resolve().is_relative_to(self.root.resolve()) or any(
                p.is_symlink() or getattr(p, 'is_junction', lambda: False)() for p in [path, *path.parents]):
            raise HTTPException(409, 'Chemin du cache KB non autorisé')
        return path

    def queue(self, context, force=False, deployment=None):
        value = context.model_dump()
        key = json.dumps(value, sort_keys=True)
        cutoff = (datetime.now(timezone.utc)-timedelta(hours=24)).isoformat()
        start = False
        with self.db(write=True) as con:
            if deployment:
                original=con.execute('SELECT j.context_key FROM windows_kb_requests r JOIN windows_kb_jobs j ON j.id=r.job_id WHERE r.deployment_id=?',(deployment,)).fetchone()
                if original and original['context_key']!=key:
                    raise HTTPException(409,'Le contexte KB de ce déploiement est déjà fixé')
            record = con.execute("SELECT * FROM windows_kb_jobs WHERE context_key=? AND (status IN ('queued','running') OR (status='ready' AND updated_at>?)) ORDER BY created_at DESC LIMIT 1", (key, cutoff if not force else '9999')).fetchone()
            if not record:
                identifier = str(uuid.uuid4())
                con.execute('INSERT INTO windows_kb_jobs VALUES (?,?,?,?,?,?,?,?)',
                    (identifier, json.dumps(value), key, 'queued', 'Recherche et téléchargement Microsoft en attente.', None, now(), now()))
                record = con.execute('SELECT * FROM windows_kb_jobs WHERE id=?', (identifier,)).fetchone()
                start = True
            if deployment:
                con.execute('INSERT OR REPLACE INTO windows_kb_requests VALUES (?,?)', (deployment, record['id']))
            result = dict(record)
        if start:
            future = self.pool.submit(self.acquire, result['id'], value)
            with self.lock: self.futures.add(future)
            future.add_done_callback(self.finished)
        return result

    def finished(self, future):
        with self.lock: self.futures.discard(future)

    def progress(self, identifier, message):
        with self.db(write=True) as con:
            con.execute('UPDATE windows_kb_jobs SET message=?,updated_at=? WHERE id=?',(message[:1500],now(),identifier))

    def acquire(self, identifier, context):
        try:
            with self.db(write=True) as con:
                con.execute("UPDATE windows_kb_jobs SET status='running',message=?,updated_at=? WHERE id=?", ('Recherche du catalogue et téléchargement des MSU Microsoft sur .250.', now(), identifier))
            plan = prepare(context['family'], context['release'], context['architecture'],
                           '' if context['dotnet']=='none' else context['dotnet'], self.checked(self.root/'packages'), on_progress=lambda message:self.progress(identifier,message))
            if (plan['family'],plan['release'],plan['architecture'],plan['dotnet'] or 'none') != (
                    context['family'],context['release'],context['architecture'],context['dotnet']):
                raise ValueError('Contexte du catalogue différent de la demande Windows')
            for group in plan['groups']:
                if group['kind']=='os' and not str(group.get('target_build','')).startswith(str(context['build'])+'.'):
                    raise ValueError('Build du correctif différent du Windows demandé')
                if not re.fullmatch(r'KB\d{6,9}', group['kb']): raise ValueError('Identifiant KB invalide')
                for entry in group['files']:
                    path = self.checked(Path(entry['path']))
                    if not re.fullmatch(r'[A-Za-z0-9_.-]+\.msu', path.name, re.I): raise ValueError('Nom de paquet Microsoft invalide')
                    if path.stat().st_size != entry['size']: raise ValueError('Paquet Microsoft incomplet')
            with self.db(write=True) as con:
                con.execute("UPDATE windows_kb_jobs SET status='ready',message=?,manifest_json=?,updated_at=? WHERE id=?",
                    ('Correctifs disponibles sur .250 pour la préparation des postes.', json.dumps(plan), now(), identifier))
        except Exception as exc:
            with self.db(write=True) as con:
                con.execute("UPDATE windows_kb_jobs SET status='failed',message=?,updated_at=? WHERE id=?", (str(exc)[:1500], now(), identifier))

    def public(self, record, deployment=None):
        result = {key:record[key] for key in ('id','status','message','created_at','updated_at')}
        result['context'] = json.loads(record['context_json'])
        result['groups'] = []
        plan = json.loads(record['manifest_json']) if record['manifest_json'] else {}
        for group in plan.get('groups', []):
            item = {k:group.get(k) for k in ('kind','kb','title','target_build','published')}
            item['files'] = []
            for entry in group['files']:
                part = {k:entry[k] for k in ('filename','size','sha256')}
                if deployment:
                    part['url'] = f"/api/windows/{deployment}/kb/{record['id']}/files/{entry['sha256']}"
                item['files'].append(part)
            result['groups'].append(item)
        return result

    def contexts(self):
        found = {}
        with self.db() as con:
            rows = con.execute('SELECT context_json FROM windows_kb_jobs ORDER BY created_at DESC').fetchall()
        for row in rows:
            value = KbContext.model_validate_json(row['context_json'])
            found[json.dumps(value.model_dump(), sort_keys=True)] = value
        # Les rapports WIM existants fournissent un contexte exact sans monter d’image.
        public = self.data/'maintenance-overview/runs'
        for path in sorted(public.glob('*.json'), reverse=True)[:100]:
            if path.is_symlink() or not path.resolve().is_relative_to(self.data.resolve()): continue
            try:
                report = json.loads(path.read_text(encoding='utf-8-sig'))
                for entry in report.get('indexes', []):
                    version = entry['version']
                    value = KbContext(family=version['family'],release=version['release'],
                        architecture=entry['architecture'],dotnet=version.get('dotnet') or 'none',build=version['build'])
                    found.setdefault(json.dumps(value.model_dump(),sort_keys=True),value)
            except (ValueError, KeyError, OSError): continue
        return list(found.values())

    def routes(self, api, windows_agent, admin):
        api.state.windows_kb = self
        @api.post('/api/windows/{identifier}/kb')
        def request(identifier:str, body:KbContext, authorization:str=Header(default='')):
            with self.db() as con: windows_agent(con,identifier,authorization)
            return self.public(self.queue(body,deployment=identifier),identifier)

        @api.get('/api/windows/{identifier}/kb/{job_id}')
        def status(identifier:str,job_id:uuid.UUID,authorization:str=Header(default='')):
            with self.db() as con:
                windows_agent(con,identifier,authorization)
                record = con.execute('SELECT j.* FROM windows_kb_jobs j JOIN windows_kb_requests r ON r.job_id=j.id WHERE r.deployment_id=? AND j.id=?',(identifier,str(job_id))).fetchone()
            if not record: raise HTTPException(403,'Correctifs absents de ce déploiement')
            return self.public(record,identifier)

        @api.get('/api/windows/{identifier}/kb/{job_id}/files/{digest}')
        def file(identifier:str,job_id:uuid.UUID,digest:str,authorization:str=Header(default='')):
            if not re.fullmatch(r'[a-f0-9]{64}',digest): raise HTTPException(404,'Paquet inconnu')
            with self.db() as con:
                windows_agent(con,identifier,authorization)
                record=con.execute("SELECT j.* FROM windows_kb_jobs j JOIN windows_kb_requests r ON r.job_id=j.id WHERE r.deployment_id=? AND j.id=? AND j.status='ready'",(identifier,str(job_id))).fetchone()
            if not record: raise HTTPException(403,'Correctifs absents de ce déploiement')
            plan=json.loads(record['manifest_json'])
            entry=next((f for g in plan['groups'] for f in g['files'] if f['sha256']==digest),None)
            if not entry: raise HTTPException(404,'Paquet inconnu')
            path=self.checked(Path(entry['path']))
            if not path.is_file() or path.stat().st_size!=entry['size']: raise HTTPException(409,'Cache KB incomplet, actualiser le dépôt')
            return FileResponse(path,media_type='application/octet-stream',filename=path.name)

        @api.get('/api/maintenance/windows/kb',dependencies=[Depends(admin)])
        def overview():
            with self.db() as con: records=con.execute('SELECT * FROM windows_kb_jobs ORDER BY created_at DESC LIMIT 100').fetchall()
            return {'jobs':[self.public(r) for r in records], 'contexts':[c.model_dump() for c in self.contexts()]}

        @api.post('/api/maintenance/windows/kb/refresh',dependencies=[Depends(admin)])
        def refresh():
            contexts=self.contexts()
            if not contexts: raise HTTPException(409,'Aucune version connue. Le premier poste transmettra son contexte Windows, ou utiliser le formulaire de version exacte.')
            return {'jobs':[self.public(self.queue(c,force=True)) for c in contexts]}

        @api.post('/api/maintenance/windows/kb/prepare',dependencies=[Depends(admin)])
        def prepare_context(body:KbContext):
            return self.public(self.queue(body,force=True))
