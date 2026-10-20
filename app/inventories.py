"""Deployment-scoped XML/CSV storage on the deployment server."""
import csv
import hashlib
import io
import json
import os
import re
import uuid
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

from fastapi import Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field

MAX_INVENTORY = 32 * 1024 * 1024
MAX_DIAGNOSTICS = 8 * 1024 * 1024
DIAGNOSTIC_NAMES = {'progress.json','result.json','maintenance.json','hpia-result.json','first-logon.log','maintenance.log','reporting.log','cleanup.log'}


class CleanupProof(BaseModel):
    model_config=ConfigDict(extra='forbid')
    report: str=Field(pattern=r'^[a-f0-9]{64}$')
    xml: str=Field(pattern=r'^[a-f0-9]{64}$')
    csv: str=Field(pattern=r'^[a-f0-9]{64}$')
    diagnostics: str=Field(pattern=r'^[a-f0-9]{64}$')


def validate_diagnostics(payload):
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            entries=archive.infolist()
            if not 1 <= len(entries) <= 256 or sum(e.file_size for e in entries)>MAX_INVENTORY:
                raise ValueError('Limite archive')
            names=set()
            for entry in entries:
                name=entry.filename
                allowed=name in DIAGNOSTIC_NAMES or re.fullmatch(r'software-logs/(?:vlc|reader|chrome|anydesk|hpia|lenovo_system_update|winget-preparation)\.log',name) or re.fullmatch(r'timings/[a-z0-9_-]{1,80}\.json',name)
                if not allowed or name in names or entry.flag_bits & 1 or (entry.external_attr>>16)&0o170000==0o120000 or entry.file_size>4*1024*1024:
                    raise ValueError('Entree archive non autorisee')
                names.add(name)
                content=archive.read(entry).decode('utf-8-sig')
                if name.endswith('.json'):json.loads(content)
            if not {'result.json','maintenance.json'} <= names:raise ValueError('Resultats absents')
    except (ValueError,UnicodeError,zipfile.BadZipFile,RuntimeError,NotImplementedError) as exc:
        raise HTTPException(422,'Archive diagnostic invalide') from exc


class Inventories:
    def __init__(self, data, db):
        self.root = data / 'inventaires'
        self.root.mkdir(exist_ok=True)
        self.db = db
        with db(write=True) as con:
            con.execute('''CREATE TABLE IF NOT EXISTS inventory_files (
                deployment_id TEXT NOT NULL REFERENCES deployments(id), kind TEXT NOT NULL,
                relative_path TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
                PRIMARY KEY(deployment_id,kind))''')
            con.execute('CREATE TABLE IF NOT EXISTS report_receipts(deployment_id TEXT PRIMARY KEY REFERENCES deployments(id),sha256 TEXT NOT NULL)')

    def folder(self, hostname, identifier):
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]{0,14}', hostname):
            raise HTTPException(409, 'Nom du poste invalide pour le dossier inventaire')
        # Windows reserved device names cannot be directory names.
        name = hostname.upper()
        if re.fullmatch(r'CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]', name):
            name += '-PC'
        return self.root / name / str(uuid.UUID(identifier))

    def checked(self, path):
        if not path.resolve().is_relative_to(self.root.resolve()):
            raise HTTPException(409, 'Dossier inventaire non autorise')
        if any((p.is_symlink() or getattr(p, 'is_junction', lambda: False)()) for p in [path, *path.parents] if p != self.root.parent):
            raise HTTPException(409, 'Lien symbolique refuse')
        return path

    def describe(self, con, identifier):
        files = [dict(r) for r in con.execute('SELECT kind,size,sha256 FROM inventory_files WHERE deployment_id=? ORDER BY kind', (identifier,))]
        for item in files:
            item['filename'] = 'Diagnostics-Deploiement.zip' if item['kind']=='diagnostics' else 'Inventaire-Technique.' + item['kind']
            item['url'] = f"/api/deployments/{identifier}/inventory/{item['kind']}"
        return {'deployment_id': identifier, 'files': files}

    def routes(self, api, windows_agent, admin, now):
        @api.post('/api/windows/{identifier}/inventory/{kind}')
        async def upload(identifier: str, kind: str, request: Request, authorization: str = Header(default='')):
            if kind not in {'xml', 'csv','diagnostics'}:
                raise HTTPException(404, 'Format inventaire inconnu')
            # Authenticate before parsing or writing any inventory data.
            with self.db() as con:
                job = windows_agent(con, identifier, authorization)
                selected = json.loads(job['selection_json'])
                hostname = selected.get('hostname') or con.execute('SELECT hostname FROM machines WHERE id=?', (job['machine_id'],)).fetchone()[0]
            limit=MAX_DIAGNOSTICS if kind=='diagnostics' else MAX_INVENTORY
            chunks=[];received=0
            async for chunk in request.stream():
                received+=len(chunk)
                if received>limit:raise HTTPException(413,'Fichier trop volumineux')
                chunks.append(chunk)
            payload=b''.join(chunks)
            if not payload:
                raise HTTPException(413, 'Inventaire vide ou trop volumineux')
            if kind=='diagnostics':validate_diagnostics(payload)
            try:
                text = '' if kind=='diagnostics' else payload.decode('utf-8-sig')
                if kind == 'xml':
                    if re.search(r'<!\s*(?:DOCTYPE|ENTITY)', text, re.I):
                        raise ValueError('DTD refusee')
                    root = ET.fromstring(text)
                    if root.tag != 'InventaireOrdinateur' or root.get('ordinateur', '').casefold() != hostname.casefold():
                        raise ValueError('Nom XML different du poste')
                elif kind=='csv':
                    reader = csv.DictReader(io.StringIO(text), delimiter=';')
                    if not {'Ordinateur', 'Categorie', 'Propriete', 'Valeur'} <= set(reader.fieldnames or []):
                        raise ValueError('Colonnes CSV absentes')
                    for item in reader:
                        if item.get('Ordinateur', '').casefold() != hostname.casefold():
                            raise ValueError('Nom CSV different du poste')
            except (ValueError, UnicodeError, ET.ParseError, csv.Error) as exc:
                raise HTTPException(422, 'Inventaire invalide : ' + str(exc)[:150]) from exc
            folder = self.checked(self.folder(hostname, identifier))
            folder.mkdir(parents=True, exist_ok=True)
            destination = self.checked(folder / ('Diagnostics-Deploiement.zip' if kind=='diagnostics' else 'Inventaire-Technique.' + kind))
            temporary = folder / (uuid.uuid4().hex + '.tmp')
            try:
                temporary.write_bytes(payload)
                with self.db(write=True) as con:
                    windows_agent(con, identifier, authorization)
                    os.replace(temporary, destination)
                    con.execute('INSERT OR REPLACE INTO inventory_files VALUES (?,?,?,?,?)',
                                (identifier, kind, str(destination.relative_to(self.root)), hashlib.sha256(payload).hexdigest(), len(payload)))
            finally:
                temporary.unlink(missing_ok=True)
            return {'accepted': True, 'filename': destination.name,'sha256':hashlib.sha256(payload).hexdigest(),'deployment_id':identifier}

        @api.post('/api/windows/{identifier}/cleanup-ready')
        def cleanup_ready(identifier:str,body:CleanupProof,authorization:str=Header(default='')):
            proof=body.model_dump()
            with self.db() as con:
                job=windows_agent(con,identifier,authorization)
                report=con.execute('SELECT sha256 FROM report_receipts WHERE deployment_id=?',(identifier,)).fetchone()
                if job['windows_status'] not in {'completed','needs_attention','failed'} or not report or report['sha256']!=proof['report']:
                    raise HTTPException(409,'Rapport courant pas encore confirme')
                for kind in ('xml','csv','diagnostics'):
                    record=con.execute('SELECT * FROM inventory_files WHERE deployment_id=? AND kind=?',(identifier,kind)).fetchone()
                    if not record or record['sha256']!=proof[kind]:raise HTTPException(409,'Transmission incomplete ou obsolete')
                    path=self.checked(self.root/record['relative_path'])
                    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=proof[kind]:raise HTTPException(409,'Archive serveur absente ou modifiee')
            return {'accepted':True,'cleanup_allowed':True,'deployment_id':identifier,'hashes':proof}

        @api.get('/api/deployments/{identifier}/inventory', dependencies=[Depends(admin)])
        def directory(identifier: str):
            with self.db() as con:
                job = con.execute('SELECT * FROM deployments WHERE id=?', (identifier,)).fetchone()
                if not job:
                    raise HTTPException(404, 'Deploiement inconnu')
                selected = json.loads(job['selection_json'])
                hostname = selected.get('hostname') or con.execute('SELECT hostname FROM machines WHERE id=?', (job['machine_id'],)).fetchone()[0]
                return {**self.describe(con, identifier), 'hostname': hostname, 'server_directory': str(self.folder(hostname, identifier))}

        @api.get('/api/deployments/{identifier}/inventory/{kind}', dependencies=[Depends(admin)])
        def download(identifier: str, kind: str):
            with self.db() as con:
                record = con.execute('SELECT * FROM inventory_files WHERE deployment_id=? AND kind=?', (identifier, kind)).fetchone()
                if not record:
                    raise HTTPException(404, 'Inventaire pas encore recu')
                path = self.checked(self.root / record['relative_path'])
                if not path.is_file() or path.stat().st_size != record['size']:
                    raise HTTPException(409, 'Fichier inventaire absent ou modifie')
            return FileResponse(path, media_type='application/octet-stream', filename=path.name)
