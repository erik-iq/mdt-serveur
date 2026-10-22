"""Demandes WinGet bornées, exécutées par un agent Windows interactif distinct."""
from datetime import datetime, timezone
import hmac
import json
import os
from pathlib import Path
import secrets
import uuid
from typing import Literal

from fastapi import Depends, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field


def timestamp():
    return datetime.now(timezone.utc).isoformat()


class Selection(BaseModel):
    model_config = ConfigDict(extra='forbid')
    packages: list[str] = Field(min_length=1, max_length=50)
    bundle_ids: list[uuid.UUID] = Field(default_factory=list, max_length=50)


class Worker(BaseModel):
    worker_id: uuid.UUID
    state: Literal['ready', 'busy', 'not_ready'] = 'ready'
    message: str = Field(default='', max_length=500)
    job_id: uuid.UUID | None = None


class Progress(Worker):
    progress: int = Field(ge=0, le=100)


class Finish(Worker):
    status: Literal['completed', 'partial', 'failed', 'interrupted']
    results: dict = Field(default_factory=dict)


class BundleApplications(BaseModel):
    application_ids: list[uuid.UUID] = Field(min_length=1, max_length=50)


class SoftwareJobs:
    def __init__(self, api, db, data, admin, sources_path):
        self.db = db
        self.sources = json.loads(Path(sources_path).read_text(encoding='utf-8-sig'))
        directory = data / 'software-sync'
        directory.mkdir(exist_ok=True)
        key_file = directory / 'worker-key'
        if not key_file.exists():
            try:
                with os.fdopen(os.open(key_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as handle:
                    handle.write(secrets.token_urlsafe(32))
            except FileExistsError:
                pass
        self.key = key_file.read_text().strip()
        if len(self.key) < 24:
            raise ValueError('Clé agent WinGet invalide : restaurer software-sync/worker-key depuis une sauvegarde privee')
        with db(write=True) as con:
            con.executescript('''
                CREATE TABLE IF NOT EXISTS software_jobs (
                    id TEXT PRIMARY KEY, packages_json TEXT NOT NULL, bundle_ids_json TEXT NOT NULL,
                    status TEXT NOT NULL, progress INTEGER NOT NULL DEFAULT 0, message TEXT NOT NULL,
                    results_json TEXT NOT NULL DEFAULT '{}', worker_id TEXT,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE UNIQUE INDEX IF NOT EXISTS software_one_active ON software_jobs((1))
                    WHERE status IN ('queued','running');
                CREATE TABLE IF NOT EXISTS software_worker (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1), worker_id TEXT NOT NULL,
                    state TEXT NOT NULL, message TEXT NOT NULL, last_seen TEXT NOT NULL);
            ''')

        def worker_auth(authorization: str = Header(default='')):
            if not hmac.compare_digest(authorization.encode(), ('Bearer ' + self.key).encode()):
                raise HTTPException(401, 'Agent logiciel non autorisé')

        @api.get('/api/software-sync', dependencies=[Depends(admin)])
        def status():
            with db() as con:
                return self.state(con)

        @api.post('/api/software-sync/jobs', status_code=202, dependencies=[Depends(admin)])
        def queue(body: Selection):
            keys = {s['key'] for s in self.sources}
            if len(set(body.packages)) != len(body.packages) or not set(body.packages) <= keys:
                raise HTTPException(400, 'Sélection de logiciels invalide')
            bundles = list(dict.fromkeys(str(b) for b in body.bundle_ids))
            with db(write=True) as con:
                self.no_active(con)
                self.no_deployments(con)
                worker = self.state(con)['worker']
                if not worker['available'] or worker['state'] != 'ready':
                    raise HTTPException(409, 'Agent WinGet indisponible. Ouvrir la session Windows configurée et vérifier WinGet.')
                for identifier in bundles:
                    if not con.execute('SELECT 1 FROM bundles WHERE id=?', (identifier,)).fetchone():
                        raise HTTPException(404, 'Bundle introuvable')
                identifier, time = str(uuid.uuid4()), timestamp()
                con.execute('''INSERT INTO software_jobs
                    (id,packages_json,bundle_ids_json,status,message,created_at,updated_at)
                    VALUES (?,?,?,'queued',?,?,?)''',
                    (identifier, json.dumps(body.packages), json.dumps(bundles), 'En attente de l’agent WinGet', time, time))
                return self.job(con.execute('SELECT * FROM software_jobs WHERE id=?', (identifier,)).fetchone())

        @api.post('/api/software-sync/jobs/{identifier}/cancel', dependencies=[Depends(admin)])
        def cancel(identifier: str):
            with db(write=True) as con:
                record = con.execute("SELECT status FROM software_jobs WHERE id=?", (identifier,)).fetchone()
                if not record:
                    raise HTTPException(404, 'Demande introuvable')
                if record['status'] != 'queued':
                    raise HTTPException(409, 'Seule une demande en attente peut être annulée. Attendre la fin du téléchargement en cours.')
                con.execute("UPDATE software_jobs SET status='interrupted',message=?,updated_at=? WHERE id=?",
                            ('Demande annulée avant son démarrage', timestamp(), identifier))
                return {'accepted': True}

        @api.post('/api/software-sync/worker/heartbeat', dependencies=[Depends(worker_auth)])
        def heartbeat(body: Worker):
            with db(write=True) as con:
                # Un nouveau processus doit obtenir le mutex système avant d’enregistrer son identité.
                previous = con.execute('SELECT worker_id FROM software_worker WHERE singleton=1').fetchone()
                if previous and previous['worker_id'] != str(body.worker_id):
                    con.execute("UPDATE software_jobs SET status='interrupted',message=?,updated_at=? WHERE status='running'",
                                ('Agent redémarre ; relancer la mise à jour', timestamp()))
                con.execute('INSERT OR REPLACE INTO software_worker VALUES (1,?,?,?,?)',
                            (str(body.worker_id), body.state, body.message, timestamp()))
                if body.job_id:
                    self.owned(con, str(body.job_id), str(body.worker_id))
                return {'accepted': True}

        @api.post('/api/software-sync/worker/claim', dependencies=[Depends(worker_auth)])
        def claim(body: Worker):
            with db(write=True) as con:
                record = con.execute('SELECT * FROM software_worker WHERE singleton=1').fetchone()
                if not record or record['worker_id'] != str(body.worker_id) or body.state != 'ready':
                    raise HTTPException(409, 'Agent non enregistré ou indisponible')
                queued = con.execute("SELECT * FROM software_jobs WHERE status='queued'").fetchone()
                if not queued:
                    return {'job': None}
                self.no_deployments(con)
                con.execute("UPDATE software_jobs SET status='running',worker_id=?,message=?,updated_at=? WHERE id=?",
                            (str(body.worker_id), 'Préparation de WinGet', timestamp(), queued['id']))
                return {'job': self.job(con.execute('SELECT * FROM software_jobs WHERE id=?', (queued['id'],)).fetchone())}

        @api.post('/api/software-sync/jobs/{identifier}/progress', dependencies=[Depends(worker_auth)])
        def progress(identifier: str, body: Progress):
            with db(write=True) as con:
                self.owned(con, identifier, str(body.worker_id))
                con.execute('UPDATE software_jobs SET progress=MAX(progress,?),message=?,updated_at=? WHERE id=?',
                            (body.progress, body.message, timestamp(), identifier))
                return {'accepted': True}

        @api.post('/api/software-sync/jobs/{identifier}/finish', dependencies=[Depends(worker_auth)])
        def finish(identifier: str, body: Finish):
            results = json.dumps(body.results, ensure_ascii=False)
            if len(results.encode()) > 64000:
                raise HTTPException(413, 'Résultat trop volumineux')
            with db(write=True) as con:
                self.owned(con, identifier, str(body.worker_id))
                con.execute("UPDATE software_jobs SET status=?,progress=CASE WHEN ?='completed' THEN 100 ELSE progress END,message=?,results_json=?,updated_at=? WHERE id=?",
                            (body.status, body.status, body.message, results, timestamp(), identifier))
                return {'accepted': True}

    @staticmethod
    def job(record):
        if not record:
            return None
        value = dict(record)
        for name in ('packages', 'bundle_ids', 'results'):
            value[name] = json.loads(value.pop(name + '_json'))
        value.pop('worker_id', None)
        return value

    def state(self, con):
        record = con.execute('SELECT * FROM software_worker WHERE singleton=1').fetchone()
        worker = dict(record) if record else {'state': 'not_ready', 'message': 'Agent WinGet non configuré', 'last_seen': None}
        worker.pop('worker_id', None)
        worker.pop('singleton', None)
        worker['available'] = bool(record and (datetime.now(timezone.utc) - datetime.fromisoformat(record['last_seen'])).total_seconds() < 30)
        return {'sources': [{k: source[k] for k in ('key', 'name', 'winget_id')} for source in self.sources],
                'worker': worker, 'job': self.job(con.execute('SELECT * FROM software_jobs ORDER BY created_at DESC LIMIT 1').fetchone())}

    @staticmethod
    def no_active(con):
        if con.execute("SELECT 1 FROM software_jobs WHERE status IN ('queued','running')").fetchone():
            raise HTTPException(409, 'Une mise à jour logicielle est déjà en cours ; attendre sa fin')

    @staticmethod
    def no_deployments(con):
        if con.execute("SELECT 1 FROM deployments WHERE status IN ('queued','running')").fetchone():
            raise HTTPException(409, 'Terminer ou annuler les autorisations WinPE actives avant la mise à jour des logiciels')

    @staticmethod
    def owned(con, identifier, worker_id):
        job = con.execute("SELECT * FROM software_jobs WHERE id=? AND status='running' AND worker_id=?", (identifier, worker_id)).fetchone()
        if not job:
            raise HTTPException(409, 'Synchronisation interrompue ou agent incorrect')
        return job

    def mutation(self, con, request: Request):
        identifier = request.headers.get('X-Atelier-Software-Job')
        if identifier:
            if not hmac.compare_digest(request.headers.get('X-Atelier-Software-Key', '').encode(), self.key.encode()):
                raise HTTPException(403, 'Clé agent requise')
            job = con.execute("SELECT id FROM software_jobs WHERE id=? AND status='running'", (identifier,)).fetchone()
            if not job:
                raise HTTPException(409, 'Synchronisation interrompue ; modification refusée')
        else:
            self.no_active(con)
