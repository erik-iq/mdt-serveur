"""Débit reçu sur l’interface du poste pendant DISM et vitesse de liaison déclarée."""
import json
import math
from typing import Literal

from fastapi import Depends, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class NetworkMeasurement(BaseModel):
    model_config = ConfigDict(extra='forbid')
    source: Literal['winpe_image_rx']
    status: Literal['measured', 'unavailable']
    application_status: Literal['completed', 'failed']
    adapter_name: str = Field(default='', max_length=180)
    link_speed_bps: int | None = Field(default=None, ge=1, le=1_000_000_000_000)
    received_bytes: int | None = Field(default=None, ge=0, le=10**16)
    duration_seconds: float | None = Field(default=None, ge=0.001, le=1209600)
    reason: str = Field(default='', max_length=500)

    @field_validator('duration_seconds')
    @classmethod
    def finite_duration(cls, value):
        if value is not None and not math.isfinite(value):
            raise ValueError('Durée réseau invalide')
        return value

    @field_validator('adapter_name', 'reason')
    @classmethod
    def printable(cls, value):
        if any(ord(character) < 32 for character in value):
            raise ValueError('Caractères de contrôle interdits')
        return value.strip()

    @model_validator(mode='after')
    def coherent(self):
        if self.status == 'measured' and (self.received_bytes is None or self.duration_seconds is None):
            raise ValueError('Octets et durée nécessaires pour mesurer le débit')
        if self.status == 'unavailable' and (self.received_bytes is not None or self.duration_seconds is not None):
            raise ValueError('Une mesure indisponible ne doit pas fournir un débit')
        return self


def network_routes(api, db, admin, windows_agent, now):
    with db(write=True) as con:
        con.execute('''CREATE TABLE IF NOT EXISTS deployment_network(
            deployment_id TEXT PRIMARY KEY REFERENCES deployments(id),
            measurement_json TEXT NOT NULL,received_at TEXT NOT NULL)''')

    @api.post('/api/windows/{identifier}/network')
    def receive(identifier: str, body: NetworkMeasurement, authorization: str = Header(default='')):
        payload = json.dumps(body.model_dump(), sort_keys=True, ensure_ascii=False)
        with db(write=True) as con:
            windows_agent(con, identifier, authorization)
            previous = con.execute('SELECT measurement_json FROM deployment_network WHERE deployment_id=?', (identifier,)).fetchone()
            if previous:
                if previous['measurement_json'] != payload:
                    raise HTTPException(409, 'Mesure réseau déjà enregistrée pour cette application Windows')
            else:
                con.execute('INSERT INTO deployment_network VALUES(?,?,?)', (identifier, payload, now()))
        return {'accepted': True}


def network_statistics(con, since, at):
    rows = con.execute('''SELECT d.id,d.created_at,d.selection_json,m.hostname,
        COALESCE(json_extract(r.report_json,'$.inventory.Modèle'),json_extract(r.report_json,'$.inventory.Modele'),'Modèle non transmis') AS model,
        n.measurement_json,n.received_at
        FROM deployments d JOIN machines m ON m.id=d.machine_id
        LEFT JOIN deployment_network n ON n.deployment_id=d.id
        LEFT JOIN computer_reports r ON r.deployment_id=d.id
        WHERE d.status!='cancelled' AND (d.status='staged' OR n.deployment_id IS NOT NULL)
          AND (? IS NULL OR julianday(d.created_at)>=julianday(?))
          AND julianday(d.created_at)<=julianday(?)
        ORDER BY d.created_at DESC,d.id DESC''', (since, since, at.isoformat()))
    samples = []
    speeds = []
    total_bytes = 0
    total_seconds = 0.0
    measured = unavailable = failed = missing = known_links = below_gigabit = 0
    applications = 0
    for row in rows:
        applications += 1
        payload = None
        if row['measurement_json']:
            try:
                payload = NetworkMeasurement.model_validate_json(row['measurement_json'])
            except ValueError:
                pass
        selected = json.loads(row['selection_json'])
        entry = {'deployment_id': row['id'], 'hostname': selected.get('hostname') or row['hostname'],
                 'model': row['model'], 'created_at': row['created_at'], 'received_at': row['received_at'],
                 'adapter_name': payload.adapter_name if payload else '',
                 'link_speed_bps': payload.link_speed_bps if payload else None,
                 'average_mbps': None, 'received_bytes': None, 'duration_seconds': None,
                 'status': 'unavailable', 'reason': 'Aucune mesure réseau reçue pour cette installation.'}
        if not payload:
            missing += 1
        elif payload.application_status != 'completed':
            failed += 1
            entry.update(status='failed', reason='Application de l’image en échec ; mesure exclue des moyennes.')
        else:
            if payload.link_speed_bps:
                known_links += 1
                below_gigabit += payload.link_speed_bps < 1_000_000_000
            if payload.status != 'measured':
                unavailable += 1
                entry['reason'] = payload.reason or 'Compteurs réseau indisponibles sur le poste.'
            else:
                measured += 1
                speed = payload.received_bytes * 8 / payload.duration_seconds / 1_000_000
                speeds.append(speed)
                total_bytes += payload.received_bytes
                total_seconds += payload.duration_seconds
                entry.update(status='measured', average_mbps=round(speed, 3), received_bytes=payload.received_bytes,
                             duration_seconds=payload.duration_seconds, reason=payload.reason)
        if len(samples) < 50:
            samples.append(entry)
    return {'applications': applications, 'measured': measured, 'unavailable': unavailable, 'missing': missing,
            'failed_applications': failed, 'known_links': known_links, 'below_gigabit': below_gigabit,
            'average_mbps': round(total_bytes * 8 / total_seconds / 1_000_000, 3) if total_seconds else None,
            'best_average_mbps': round(max(speeds), 3) if speeds else None,
            'lowest_average_mbps': round(min(speeds), 3) if speeds else None,
            'samples': samples, 'listed': len(samples), 'list_limit': 50}
