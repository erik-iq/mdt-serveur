"""CMSL repository jobs and immutable, deployment-scoped offline snapshots.

Only the local Windows worker downloads HP packages. Clients submit platform/OS
identifiers, never URLs, paths or commands. Published archives are read-only.
"""
from datetime import datetime, timezone, timedelta
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import uuid
import zipfile

from fastapi import Depends, Header, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal

MAX_REPOSITORY = 20 * 1024**3


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def public_path(name):
    parts=name.split('/')
    if not name or len(name)>240 or any(p in {'','..','.'} or not re.fullmatch(r'[A-Za-z0-9_. -]+',p) for p in parts):return False
    if len(parts)==1:return bool(re.fullmatch(r'sp[0-9]{4,8}\.(?:exe|cva|html)',name,re.I))
    return parts[:2]==['.repository','cache'] and name.lower().endswith(('.cab','.xml','.json','.cva','.html','.txt'))


class RepositoryRequest(BaseModel):
    model_config=ConfigDict(extra='forbid')
    platform: str=Field(pattern=r'^[A-Fa-f0-9]{4}$')
    os: Literal['win10','win11']
    os_version: str=Field(pattern=r'^(?:[12][0-9]H[12]|1809|1903|1909|2004|2009)$')
    required_softpaqs: list[str]=Field(default_factory=list,max_length=200)
    package_cache: bool=False


class WorkerMessage(BaseModel):
    model_config=ConfigDict(extra='forbid')
    worker_id: uuid.UUID
    state: Literal['ready','busy','not_ready']='ready'
    message: str=Field(default='',max_length=500)


class WorkerFinish(WorkerMessage):
    success: bool


class HpRepository:
    def __init__(self,data,db):
        self.root=data/'hp-repository'
        self.root.mkdir(exist_ok=True)
        (self.root/'snapshots').mkdir(exist_ok=True)
        self.db=db
        key=self.root/'worker-key'
        if not key.exists():
            try:
                with os.fdopen(os.open(key,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600),'w') as f:f.write(secrets.token_urlsafe(32))
            except FileExistsError:pass
        self.key=key.read_text().strip()
        if len(self.key)<24:raise ValueError('Cle agent HP invalide')
        with db(write=True) as con:
            con.executescript('''
                CREATE TABLE IF NOT EXISTS hp_repository_jobs (
                    id TEXT PRIMARY KEY, platform TEXT NOT NULL, os TEXT NOT NULL, os_version TEXT NOT NULL,
                    status TEXT NOT NULL, message TEXT NOT NULL, worker_id TEXT,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE UNIQUE INDEX IF NOT EXISTS hp_repository_active ON hp_repository_jobs(platform,os,os_version)
                    WHERE status IN ('queued','running');
                CREATE TABLE IF NOT EXISTS hp_repository_snapshots (
                    id TEXT PRIMARY KEY, platform TEXT NOT NULL, os TEXT NOT NULL, os_version TEXT NOT NULL,
                    sha256 TEXT NOT NULL, size INTEGER NOT NULL, softpaqs_json TEXT NOT NULL, created_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS hp_repository_requests (
                    deployment_id TEXT PRIMARY KEY REFERENCES deployments(id), platform TEXT NOT NULL,
                    os TEXT NOT NULL, os_version TEXT NOT NULL, required_json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS hp_repository_worker (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1), worker_id TEXT NOT NULL,
                    state TEXT NOT NULL, message TEXT NOT NULL, last_seen TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS hp_repository_attempts (
                    deployment_id TEXT NOT NULL REFERENCES deployments(id), request_hash TEXT NOT NULL,
                    job_id TEXT NOT NULL REFERENCES hp_repository_jobs(id), PRIMARY KEY(deployment_id,request_hash));
                CREATE TABLE IF NOT EXISTS hp_repository_leases (
                    deployment_id TEXT NOT NULL REFERENCES deployments(id), snapshot_id TEXT NOT NULL,
                    expires TEXT NOT NULL, PRIMARY KEY(deployment_id,snapshot_id));
                CREATE TABLE IF NOT EXISTS hp_package_cache_snapshots (
                    snapshot_id TEXT PRIMARY KEY REFERENCES hp_repository_snapshots(id) ON DELETE CASCADE);
            ''')

    def checked(self,path):
        if not path.resolve().is_relative_to(self.root.resolve()) or any(p.is_symlink() or getattr(p,'is_junction',lambda:False)() for p in [path,*path.parents]):
            raise HTTPException(409,'Chemin depot HP non autorise')
        return path

    @staticmethod
    def identity(body):return (body.platform.upper(),body.os,body.os_version.upper())

    @staticmethod
    def required(body):
        if any(not re.fullmatch(r'SP[0-9]{4,8}',p,re.I) for p in body.required_softpaqs):raise HTTPException(422,'Identifiant SoftPaq invalide')
        return sorted(set(p.upper() for p in body.required_softpaqs))

    def queue(self,con,key,force=False):
        active=con.execute("SELECT * FROM hp_repository_jobs WHERE platform=? AND os=? AND os_version=? AND status IN ('queued','running')",key).fetchone()
        if active:return dict(active)
        previous=con.execute('SELECT * FROM hp_repository_jobs WHERE platform=? AND os=? AND os_version=? ORDER BY created_at DESC LIMIT 1',key).fetchone()
        if previous and previous['status']=='failed' and not force and previous['updated_at']>(datetime.now(timezone.utc)-timedelta(minutes=10)).isoformat():return dict(previous)
        if con.execute("SELECT COUNT(*) FROM hp_repository_jobs WHERE status IN ('queued','running')").fetchone()[0]>=128:
            raise HTTPException(429,'File de synchronisation HP pleine')
        identifier=str(uuid.uuid4());time=timestamp()
        con.execute('INSERT INTO hp_repository_jobs VALUES (?,?,?,?,?,?,NULL,?,?)',(identifier,*key,'queued','Preparation du depot HP demandee',time,time))
        return dict(con.execute('SELECT * FROM hp_repository_jobs WHERE id=?',(identifier,)).fetchone())

    def state(self,con):
        worker=con.execute('SELECT state,message,last_seen FROM hp_repository_worker WHERE singleton=1').fetchone()
        agent=dict(worker) if worker else {'state':'not_ready','message':'Agent CMSL non configure','last_seen':None}
        agent['available']=bool(worker and worker['state'] in {'ready','busy'} and worker['last_seen']>(datetime.now(timezone.utc)-timedelta(seconds=90)).isoformat())
        jobs=[dict(r) for r in con.execute('SELECT id,platform,os,os_version,status,message,created_at,updated_at FROM hp_repository_jobs ORDER BY created_at DESC LIMIT 100')]
        snapshots=[dict(r) for r in con.execute('SELECT id,platform,os,os_version,size,created_at FROM hp_repository_snapshots ORDER BY created_at DESC LIMIT 100')]
        return {'worker':agent,'jobs':jobs,'snapshots':snapshots}

    @staticmethod
    def selected(job):
        selected=json.loads(job['selection_json'])
        if 'hpia' not in selected.get('settings',{}).get('winget_packages',[]):raise HTTPException(403,'HP Image Assistant non selectionne')

    def routes(self,api,windows_agent,admin):
        def worker_auth(authorization:str=Header(default='')):
            if not hmac.compare_digest(authorization.encode(),('Bearer '+self.key).encode()):raise HTTPException(401,'Agent HP non autorise')

        @api.get('/api/hp-repository',dependencies=[Depends(admin)])
        def status():
            with self.db() as con:return self.state(con)

        @api.post('/api/hp-repository/refresh',dependencies=[Depends(admin)])
        def refresh():
            with self.db(write=True) as con:
                keys={tuple(r) for r in con.execute('SELECT DISTINCT platform,os,os_version FROM hp_repository_requests')}
                ids=[self.queue(con,key,force=True)['id'] for key in sorted(keys)]
            return {'accepted':True,'jobs':ids}

        @api.post('/api/windows/{identifier}/hp-repository')
        def request(identifier:str,body:RepositoryRequest,authorization:str=Header(default='')):
            key=self.identity(body);required=self.required(body)
            with self.db(write=True) as con:
                self.selected(windows_agent(con,identifier,authorization))
                previous=con.execute('SELECT platform,os,os_version FROM hp_repository_requests WHERE deployment_id=?',(identifier,)).fetchone()
                if previous and tuple(previous)!=key:raise HTTPException(409,'Identite HP deja fixee pour ce deploiement')
                con.execute('INSERT OR REPLACE INTO hp_repository_requests VALUES (?,?,?,?,?)',(identifier,*key,json.dumps(required)))
                snapshot=con.execute('SELECT * FROM hp_repository_snapshots WHERE platform=? AND os=? AND os_version=? ORDER BY created_at DESC LIMIT 1',key).fetchone()
                complete=bool(snapshot and set(required)<=set(json.loads(snapshot['softpaqs_json'])))
                fresh=bool(snapshot and snapshot['created_at']>(datetime.now(timezone.utc)-timedelta(hours=24)).isoformat())
                request_hash=hashlib.sha256(json.dumps(required).encode()).hexdigest()
                attempted=con.execute('''SELECT j.status FROM hp_repository_attempts a JOIN hp_repository_jobs j ON j.id=a.job_id
                    WHERE a.deployment_id=? AND a.request_hash=?''',(identifier,request_hash)).fetchone()
                if complete and fresh:job=None
                elif snapshot and fresh and attempted and attempted['status']=='completed':
                    job={'status':'unavailable','message':'Les SoftPaq demandes restent absents de la reference CMSL ; utilisation directe de HP'}
                else:
                    job=self.queue(con,key)
                    con.execute('INSERT OR REPLACE INTO hp_repository_attempts VALUES (?,?,?)',(identifier,request_hash,job['id']))
                available=complete and fresh
                packages_only=bool(snapshot and con.execute('SELECT 1 FROM hp_package_cache_snapshots WHERE snapshot_id=?',(snapshot['id'],)).fetchone())
                if packages_only and not body.package_cache:
                    available=False
                    job={'status':'unavailable','message':'Ce cache SoftPaq exige le nouveau client Atelier ; utilisation directe de HP'}
                response={'status':'ready' if available else (job['status'] if job else 'unavailable'),'message':'Depot HP disponible' if available else (job['message'] if job else 'Depot HP indisponible'),'platform':key[0],'os':key[1],'os_version':key[2],'snapshot':None}
                agent=con.execute('SELECT state,last_seen FROM hp_repository_worker WHERE singleton=1').fetchone()
                response['worker_available']=bool(agent and agent['state'] in {'ready','busy'} and agent['last_seen']>(datetime.now(timezone.utc)-timedelta(seconds=90)).isoformat())
                if available:
                    path=self.checked(self.root/'snapshots'/(snapshot['id']+'.zip'))
                    if not path.is_file() or path.stat().st_size!=snapshot['size']:raise HTTPException(409,'Archive HP absente ou modifiee')
                    self.lease(con,identifier,snapshot['id'])
                    response['snapshot']={'id':snapshot['id'],'sha256':snapshot['sha256'],'size':snapshot['size'],'url':f'/api/windows/{identifier}/hp-repository/{snapshot["id"]}.zip'}
                return response

        @api.get('/api/windows/{identifier}/hp-repository/{snapshot_id}.zip')
        def download(identifier:str,snapshot_id:uuid.UUID,authorization:str=Header(default='')):
            with self.db(write=True) as con:
                self.selected(windows_agent(con,identifier,authorization))
                requested=con.execute('SELECT * FROM hp_repository_requests WHERE deployment_id=?',(identifier,)).fetchone()
                record=con.execute('SELECT * FROM hp_repository_snapshots WHERE id=?',(str(snapshot_id),)).fetchone()
                if not requested or not record or tuple(requested[k] for k in ('platform','os','os_version'))!=tuple(record[k] for k in ('platform','os','os_version')):raise HTTPException(403,'Archive HP absente de ce deploiement')
                if not set(json.loads(requested['required_json']))<=set(json.loads(record['softpaqs_json'])):raise HTTPException(409,'SoftPaq demandes absents de cette archive')
                path=self.checked(self.root/'snapshots'/(str(snapshot_id)+'.zip'))
                if not path.is_file() or path.stat().st_size!=record['size']:raise HTTPException(409,'Archive HP modifiee')
                self.lease(con,identifier,str(snapshot_id))
            return FileResponse(path,media_type='application/zip',filename='HP-'+record['platform']+'-'+record['os_version']+'.zip')

        @api.post('/api/hp-repository/worker/heartbeat',dependencies=[Depends(worker_auth)])
        def heartbeat(body:WorkerMessage):
            with self.db(write=True) as con:
                previous=con.execute('SELECT worker_id FROM hp_repository_worker WHERE singleton=1').fetchone()
                if previous and previous['worker_id']!=str(body.worker_id):
                    con.execute("UPDATE hp_repository_jobs SET status='failed',message='Agent CMSL redemarre ; synchronisation a reprendre',updated_at=? WHERE status='running'",(timestamp(),))
                con.execute('INSERT OR REPLACE INTO hp_repository_worker VALUES (1,?,?,?,?)',(str(body.worker_id),body.state,body.message,timestamp()))
            return {'accepted':True}

        @api.post('/api/hp-repository/worker/claim',dependencies=[Depends(worker_auth)])
        def claim(body:WorkerMessage):
            with self.db(write=True) as con:
                worker=con.execute('SELECT * FROM hp_repository_worker WHERE singleton=1').fetchone()
                if not worker or worker['worker_id']!=str(body.worker_id) or body.state!='ready':raise HTTPException(409,'Agent HP indisponible')
                if con.execute("SELECT 1 FROM hp_repository_jobs WHERE status='running'").fetchone():return {'job':None}
                # Refresh known platforms daily, outside the client installation.
                cutoff=(datetime.now(timezone.utc)-timedelta(hours=24)).isoformat()
                for key in con.execute('SELECT DISTINCT platform,os,os_version FROM hp_repository_requests').fetchall():
                    last=con.execute('SELECT created_at FROM hp_repository_jobs WHERE platform=? AND os=? AND os_version=? ORDER BY created_at DESC LIMIT 1',tuple(key)).fetchone()
                    if last and last['created_at']<cutoff:self.queue(con,tuple(key))
                record=con.execute("SELECT * FROM hp_repository_jobs WHERE status='queued' ORDER BY created_at LIMIT 1").fetchone()
                if not record:return {'job':None}
                con.execute("UPDATE hp_repository_jobs SET status='running',worker_id=?,message='Synchronisation CMSL des SoftPaq',updated_at=? WHERE id=?",(str(body.worker_id),timestamp(),record['id']))
                required=set()
                for request in con.execute('SELECT required_json FROM hp_repository_requests WHERE platform=? AND os=? AND os_version=?',(record['platform'],record['os'],record['os_version'])):
                    required.update(json.loads(request['required_json']))
                return {'job':{**{k:record[k] for k in ('id','platform','os','os_version')},'required_softpaqs':sorted(required)}}

        @api.post('/api/hp-repository/worker/jobs/{identifier}/finish',dependencies=[Depends(worker_auth)])
        def finish(identifier:uuid.UUID,body:WorkerFinish):
            with self.db() as con:owned=self.owned(con,str(identifier),str(body.worker_id))
            snapshot=self.validate_snapshot(str(identifier),owned['platform'],owned['os'],owned['os_version']) if body.success else None
            with self.db(write=True) as con:
                job=self.owned(con,str(identifier),str(body.worker_id))
                if snapshot:
                    con.execute('INSERT INTO hp_repository_snapshots VALUES (?,?,?,?,?,?,?,?)',(str(identifier),job['platform'],job['os'],job['os_version'],snapshot['sha256'],snapshot['size'],json.dumps(snapshot['softpaqs']),timestamp()))
                    if snapshot['mode']=='packages_only':
                        con.execute('INSERT INTO hp_package_cache_snapshots VALUES (?)',(str(identifier),))
                con.execute('UPDATE hp_repository_jobs SET status=?,message=?,updated_at=? WHERE id=?',('completed' if snapshot else 'failed',body.message or ('Depot HP publie' if snapshot else 'Synchronisation HP en echec'),timestamp(),str(identifier)))
            self.prune()
            return {'accepted':True}

    @staticmethod
    def lease(con,deployment_id,snapshot_id):
        # Longer than the bounded 15-minute client transfer. This protects a
        # descriptor already delivered to a PC while a new version is published.
        expires=(datetime.now(timezone.utc)+timedelta(hours=2)).isoformat()
        con.execute('INSERT OR REPLACE INTO hp_repository_leases VALUES (?,?,?)',(deployment_id,snapshot_id,expires))

    def prune(self):
        with self.db(write=True) as con:
            con.execute('DELETE FROM hp_repository_leases WHERE expires<?',(timestamp(),))
            leased={r[0] for r in con.execute('SELECT DISTINCT snapshot_id FROM hp_repository_leases')}
            retained={}
            for record in con.execute('SELECT * FROM hp_repository_snapshots ORDER BY created_at DESC').fetchall():
                key=(record['platform'],record['os'],record['os_version'])
                retained[key]=retained.get(key,0)+1
                if retained[key]<=3 or record['id'] in leased:continue
                try:
                    self.checked(self.root/'snapshots'/(str(uuid.UUID(record['id']))+'.zip')).unlink(missing_ok=True)
                except (OSError,HTTPException):continue
                con.execute('DELETE FROM hp_repository_snapshots WHERE id=?',(record['id'],))

    @staticmethod
    def owned(con,identifier,worker_id):
        job=con.execute('SELECT * FROM hp_repository_jobs WHERE id=?',(identifier,)).fetchone()
        if not job or job['status']!='running' or job['worker_id']!=worker_id:raise HTTPException(409,'Demande HP non detenue par cet agent')
        return job

    def validate_snapshot(self,identifier,platform,os_name=None,os_version=None):
        path=self.checked(self.root/'snapshots'/(identifier+'.zip'))
        if not path.is_file() or not 0<path.stat().st_size<=MAX_REPOSITORY:raise HTTPException(422,'Taille du depot HP invalide')
        softpaqs=set();names=set();reference=False;platforms=False;marker=None
        try:
            with zipfile.ZipFile(path) as archive:
                entries=archive.infolist()
                if not 1<=len(entries)<=5000 or sum(e.file_size for e in entries)>MAX_REPOSITORY:raise ValueError('Limite du depot')
                for entry in entries:
                    name=entry.filename
                    if not public_path(name) or name.casefold() in names or entry.flag_bits&1 or (entry.external_attr>>16)&0o170000==0o120000:raise ValueError('Chemin du depot invalide')
                    names.add(name.casefold())
                    if name.lower().endswith('.exe'):softpaqs.add(Path(name).stem.upper())
                    if name=='.repository/cache/atelier-softpaq-cache.json':
                        if entry.file_size>65536:raise ValueError('Description du cache HP trop grande')
                        marker=json.loads(archive.read(entry).decode('utf-8-sig'))
                    if name.startswith('.repository/cache/') and name.lower().endswith('.cab'):
                        if Path(name).name.lower()=='platformlist.cab':platforms=True
                        elif Path(name).name.upper().startswith(platform+'_'):reference=True
            if marker is not None:
                ids=marker.get('softpaqs') if isinstance(marker,dict) else None
                if (not isinstance(ids,list) or not 1<=len(ids)<=200 or any(not isinstance(p,str) or not re.fullmatch(r'SP[0-9]{4,8}',p) for p in ids)
                    or marker.get('schema')!=1 or marker.get('mode')!='packages_only' or marker.get('platform')!=platform
                    or marker.get('os')!=os_name or marker.get('os_version')!=os_version or set(ids)!=softpaqs
                    or any(p.lower()+'.cva' not in names for p in ids)):
                    raise ValueError('Identite ou contenu du cache SoftPaq incoherent')
            elif not platforms or not reference:raise ValueError('References HP hors ligne absentes')
        except (ValueError,zipfile.BadZipFile) as exc:raise HTTPException(422,str(exc)) from exc
        digest=hashlib.sha256()
        with path.open('rb') as f:
            for block in iter(lambda:f.read(1024*1024),b''):digest.update(block)
        return {'sha256':digest.hexdigest(),'size':path.stat().st_size,'softpaqs':sorted(softpaqs),'mode':'packages_only' if marker is not None else 'offline'}
