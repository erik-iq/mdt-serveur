"""Deployment-scoped XML/CSV storage on the deployment server."""
import csv
import hashlib
import io
import json
import os
import re
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

from fastapi import Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse

MAX_INVENTORY = 32 * 1024 * 1024


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
            raise HTTPException(409, 'Dossier inventaire non autorisé')
        if any((p.is_symlink() or getattr(p, 'is_junction', lambda: False)()) for p in [path, *path.parents] if p != self.root.parent):
            raise HTTPException(409, 'Lien symbolique refusé')
        return path

    def describe(self, con, identifier):
        files = [dict(r) for r in con.execute('SELECT kind,size,sha256 FROM inventory_files WHERE deployment_id=? ORDER BY kind', (identifier,))]
        for item in files:
            item['filename'] = 'Inventaire-Technique.' + item['kind']
            item['url'] = f"/api/deployments/{identifier}/inventory/{item['kind']}"
        return {'deployment_id': identifier, 'files': files}

    def routes(self, api, windows_agent, admin, now):
        @api.post('/api/windows/{identifier}/inventory/{kind}')
        async def upload(identifier: str, kind: str, request: Request, authorization: str = Header(default='')):
            if kind not in {'xml', 'csv'}:
                raise HTTPException(404, 'Format inventaire inconnu')
            # Authenticate before parsing or writing any inventory data.
            with self.db() as con:
                job = windows_agent(con, identifier, authorization)
                selected = json.loads(job['selection_json'])
                hostname = selected.get('hostname') or con.execute('SELECT hostname FROM machines WHERE id=?', (job['machine_id'],)).fetchone()[0]
            payload = await request.body()
            if not payload or len(payload) > MAX_INVENTORY:
                raise HTTPException(413, 'Inventaire vide ou trop volumineux')
            try:
                text = payload.decode('utf-8-sig')
                if kind == 'xml':
                    if re.search(r'<!\s*(?:DOCTYPE|ENTITY)', text, re.I):
                        raise ValueError('DTD refusée')
                    root = ET.fromstring(text)
                    if root.tag != 'InventaireOrdinateur' or root.get('ordinateur', '').casefold() != hostname.casefold():
                        raise ValueError('Nom XML différent du poste')
                else:
                    reader = csv.DictReader(io.StringIO(text), delimiter=';')
                    if not {'Ordinateur', 'Categorie', 'Propriete', 'Valeur'} <= set(reader.fieldnames or []):
                        raise ValueError('Colonnes CSV absentes')
                    for item in reader:
                        if item.get('Ordinateur', '').casefold() != hostname.casefold():
                            raise ValueError('Nom CSV différent du poste')
            except (ValueError, UnicodeError, ET.ParseError, csv.Error) as exc:
                raise HTTPException(422, 'Inventaire invalide : ' + str(exc)[:150]) from exc
            folder = self.checked(self.folder(hostname, identifier))
            folder.mkdir(parents=True, exist_ok=True)
            destination = self.checked(folder / ('Inventaire-Technique.' + kind))
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
            return {'accepted': True, 'filename': destination.name}

        @api.get('/api/deployments/{identifier}/inventory', dependencies=[Depends(admin)])
        def directory(identifier: str):
            with self.db() as con:
                job = con.execute('SELECT * FROM deployments WHERE id=?', (identifier,)).fetchone()
                if not job:
                    raise HTTPException(404, 'Déploiement inconnu')
                selected = json.loads(job['selection_json'])
                hostname = selected.get('hostname') or con.execute('SELECT hostname FROM machines WHERE id=?', (job['machine_id'],)).fetchone()[0]
                return {**self.describe(con, identifier), 'hostname': hostname, 'server_directory': str(self.folder(hostname, identifier))}

        @api.get('/api/deployments/{identifier}/inventory/{kind}', dependencies=[Depends(admin)])
        def download(identifier: str, kind: str):
            with self.db() as con:
                record = con.execute('SELECT * FROM inventory_files WHERE deployment_id=? AND kind=?', (identifier, kind)).fetchone()
                if not record:
                    raise HTTPException(404, 'Inventaire pas encore reçu')
                path = self.checked(self.root / record['relative_path'])
                if not path.is_file() or path.stat().st_size != record['size']:
                    raise HTTPException(409, 'Fichier inventaire absent ou modifié')
            return FileResponse(path, media_type='application/octet-stream', filename=path.name)
