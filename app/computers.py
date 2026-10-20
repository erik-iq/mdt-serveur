"""Computer history, operator notes and measured deployment stages."""
import json
import math
import uuid
from datetime import datetime
from typing import Literal

from app.identity import public_machine

from fastapi import Depends, Header, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field, field_validator

STAGES={'image':'Application de Windows','software':'Logiciels','manufacturer_tools':'Preparation des outils constructeur','hp_updates':'Mises a jour HP','windows_update':'Windows Update','inventory':'Inventaire','personalization':'Personnalisation'}


class Measurement(BaseModel):
    model_config=ConfigDict(extra='forbid')
    run_id: uuid.UUID
    source: Literal['winpe','windows']
    stage: Literal['image','software','manufacturer_tools','hp_updates','windows_update','inventory','personalization']
    status: Literal['running','completed','failed','deferred','interrupted']
    started_at: datetime
    duration_seconds: float=Field(ge=0,le=1209600)

    @field_validator('duration_seconds')
    @classmethod
    def finite(cls,value):
        if not math.isfinite(value):raise ValueError('Duree invalide')
        return value

    @field_validator('started_at')
    @classmethod
    def aware(cls,value):
        if value.utcoffset() is None:raise ValueError('Fuseau horaire requis')
        return value


class Measurements(BaseModel):
    model_config=ConfigDict(extra='forbid')
    measurements: list[Measurement]=Field(max_length=200)


class Note(BaseModel):
    model_config=ConfigDict(extra='forbid')
    text: str=Field(min_length=1,max_length=4000)
    author: str=Field(default='',max_length=80)

    @field_validator('text','author')
    @classmethod
    def printable(cls,value):
        value=value.strip()
        if any(ord(c)<32 and c not in '\n\r\t' for c in value):raise ValueError('Caracteres de controle interdits')
        return value


def computer_routes(api,db,admin,windows_agent,now):
    with db(write=True) as con:
        con.executescript('''CREATE TABLE IF NOT EXISTS machine_notes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,machine_id TEXT NOT NULL REFERENCES machines(id),
            text TEXT NOT NULL,author TEXT NOT NULL,created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS deployment_timings(
            deployment_id TEXT NOT NULL REFERENCES deployments(id),run_id TEXT NOT NULL,
            source TEXT NOT NULL,stage TEXT NOT NULL,status TEXT NOT NULL,started_at TEXT NOT NULL,
            duration_seconds REAL NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(deployment_id,run_id));
            CREATE INDEX IF NOT EXISTS machine_notes_machine ON machine_notes(machine_id,id);
            CREATE INDEX IF NOT EXISTS deployment_machine_history ON deployments(machine_id,created_at DESC,id);''')

    def timing_list(con,identifier):
        rows=[dict(r) for r in con.execute('SELECT run_id,source,stage,status,started_at,duration_seconds,updated_at FROM deployment_timings WHERE deployment_id=? ORDER BY started_at,run_id',(identifier,))]
        return [dict(r,label=STAGES[r['stage']]) for r in rows]

    @api.post('/api/windows/{identifier}/timings')
    def receive_timings(identifier:str,body:Measurements,authorization:str=Header(default='')):
        with db(write=True) as con:
            windows_agent(con,identifier,authorization)
            count=con.execute('SELECT COUNT(*) FROM deployment_timings WHERE deployment_id=?',(identifier,)).fetchone()[0]
            for item in body.measurements:
                run=str(item.run_id)
                previous=con.execute('SELECT * FROM deployment_timings WHERE deployment_id=? AND run_id=?',(identifier,run)).fetchone()
                if previous:
                    if previous['source']!=item.source or previous['stage']!=item.stage:raise HTTPException(409,'Identite de mesure differente')
                    if previous['status']!='running' and item.status=='running':continue
                    if item.duration_seconds<previous['duration_seconds']:continue
                elif count>=200:raise HTTPException(409,'Limite de mesures atteinte')
                else:count+=1
                con.execute('''INSERT INTO deployment_timings VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(deployment_id,run_id) DO UPDATE SET status=excluded.status,duration_seconds=excluded.duration_seconds,updated_at=excluded.updated_at''',
                    (identifier,run,item.source,item.stage,item.status,item.started_at.isoformat(),item.duration_seconds,now()))
        return {'accepted':True}

    @api.get('/api/deployments/{identifier}/timings',dependencies=[Depends(admin)])
    def timings(identifier:str):
        with db() as con:
            if not con.execute('SELECT id FROM deployments WHERE id=?',(identifier,)).fetchone():raise HTTPException(404,'Deploiement introuvable')
            return {'measurements':timing_list(con,identifier)}

    @api.get('/api/deployments/{identifier}/report',dependencies=[Depends(admin)])
    def report(identifier:str):
        with db() as con:
            row=con.execute('SELECT report_json FROM computer_reports WHERE deployment_id=?',(identifier,)).fetchone()
            if not row:raise HTTPException(404,'Rapport pas encore recu')
            return json.loads(row['report_json'])

    @api.post('/api/machines/{identifier}/notes',dependencies=[Depends(admin)],status_code=201)
    def add_note(identifier:str,body:Note):
        if not body.text:raise HTTPException(422,'Observation vide')
        with db(write=True) as con:
            if not con.execute('SELECT id FROM machines WHERE id=?',(identifier,)).fetchone():raise HTTPException(404,'Poste introuvable')
            key=con.execute('INSERT INTO machine_notes(machine_id,text,author,created_at) VALUES(?,?,?,?)',(identifier,body.text,body.author,now())).lastrowid
            return dict(con.execute('SELECT * FROM machine_notes WHERE id=?',(key,)).fetchone())

    @api.get('/api/machines/{identifier}/details',dependencies=[Depends(admin)])
    def detail(identifier:str,offset:int=Query(default=0,ge=0),limit:int=Query(default=50,ge=1,le=100)):
        with db() as con:
            machine=con.execute('SELECT * FROM machines WHERE id=?',(identifier,)).fetchone()
            if not machine:raise HTTPException(404,'Poste introuvable')
            total=con.execute('SELECT COUNT(*) FROM deployments WHERE machine_id=?',(identifier,)).fetchone()[0]
            history=[dict(r) for r in con.execute('''SELECT d.id,d.status,d.windows_status,d.windows_message,d.created_at,d.updated_at,d.selection_json,p.name AS profile_name,
                EXISTS(SELECT 1 FROM computer_reports r WHERE r.deployment_id=d.id) AS has_report,
                EXISTS(SELECT 1 FROM inventory_files i WHERE i.deployment_id=d.id) AS has_inventory
                FROM deployments d JOIN profiles p ON p.id=d.profile_id WHERE d.machine_id=? ORDER BY d.created_at DESC,d.id LIMIT ? OFFSET ?''',(identifier,limit,offset))]
            for item in history:
                item['hostname']=json.loads(item.pop('selection_json')).get('hostname',machine['hostname'])
                item['timings']=timing_list(con,item['id'])
            latest=con.execute('''SELECT r.deployment_id,r.report_json FROM computer_reports r JOIN deployments d ON r.deployment_id=d.id WHERE d.machine_id=? ORDER BY d.created_at DESC,d.id LIMIT 1''',(identifier,)).fetchone()
            snapshot=json.loads(latest['report_json']) if latest else None
            notes=[dict(r) for r in con.execute('SELECT id,text,author,created_at FROM machine_notes WHERE machine_id=? ORDER BY id DESC',(identifier,))]
            return {'machine':public_machine(machine),'deployments':history,'total':total,'offset':offset,'limit':limit,'has_more':offset+len(history)<total,
                    'latest_report':snapshot,'latest_report_deployment_id':latest['deployment_id'] if latest else None,'notes':notes}
