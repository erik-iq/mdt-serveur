"""Statistiques des résultats définitifs et des chronométrages réellement reçus."""
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import math

from fastapi import Depends, Query

from app.computers import STAGES

FINAL = {'completed', 'failed', 'needs_attention'}


def union_seconds(measurements):
    """Cumuler les intervalles sans compter deux fois les mesures simultanées."""
    sources = defaultdict(list)
    for item in measurements:
        sources[item['source']].append((item['start'], item['start'] + item['duration_seconds']))
    total = 0.0
    for intervals in sources.values():
        right = None
        for start, end in sorted(intervals):
            if right is None or start >= right:
                total += end - start
            elif end > right:
                total += end - right
            right = max(end, right) if right is not None else end
    return total


def mean(values):
    return round(sum(values) / len(values), 3) if values else None


def deployment_statistics(con, *, days=30, at=None):
    at = at or datetime.now(timezone.utc)
    since = (at - timedelta(days=days)).isoformat() if days else None
    # Lire l’inventaire du déploiement concerné, jamais celui d’une installation ultérieure.
    rows = con.execute('''SELECT d.id,d.status,d.windows_status,
        json_extract(r.report_json,'$.status') AS report_status,
        COALESCE(json_extract(r.report_json,'$.inventory.Constructeur'),'') AS manufacturer,
        COALESCE(json_extract(r.report_json,'$.inventory.Modèle'),
                 json_extract(r.report_json,'$.inventory.Modele'),'') AS model
        FROM deployments d LEFT JOIN computer_reports r ON r.deployment_id=d.id
        WHERE (? IS NULL OR julianday(d.created_at)>=julianday(?))
          AND julianday(d.created_at)<=julianday(?)''', (since, since, at.isoformat()))
    counts = {'finished': 0, 'completed': 0, 'failed': 0, 'needs_attention': 0,
              'excluded_unfinished': 0, 'excluded_cancelled': 0, 'timed_successful': 0,
              'partial_successful': 0, 'unmeasured_successful': 0}
    models = {}
    successes = {}
    for row in rows:
        if row['status'] == 'cancelled':
            counts['excluded_cancelled'] += 1
            continue
        if row['status'] == 'failed':
            outcome = 'failed'
        elif row['status'] == 'staged' and row['windows_status'] in FINAL and row['report_status'] == row['windows_status']:
            outcome = row['windows_status']
        else:
            counts['excluded_unfinished'] += 1
            continue
        manufacturer = ' '.join(row['manufacturer'].split()) or 'Constructeur non transmis'
        model = ' '.join(row['model'].split()) or 'Modèle non transmis'
        key = (manufacturer.casefold(), model.casefold())
        entry = models.setdefault(key, {'manufacturer': manufacturer, 'model': model,
            'finished': 0, 'completed': 0, 'failed': 0, 'needs_attention': 0,
            'timed_successful': 0, 'durations': []})
        counts['finished'] += 1
        counts[outcome] += 1
        entry['finished'] += 1
        entry[outcome] += 1
        if outcome == 'completed':
            successes[row['id']] = key

    measurements = defaultdict(list)
    incomplete = set()
    for row in con.execute('''SELECT t.* FROM deployment_timings t JOIN deployments d ON d.id=t.deployment_id
        WHERE d.status='staged' AND d.windows_status='completed'
          AND (? IS NULL OR julianday(d.created_at)>=julianday(?))
          AND julianday(d.created_at)<=julianday(?)''', (since, since, at.isoformat())):
        identifier = row['deployment_id']
        if identifier not in successes:
            continue
        if row['status'] != 'completed':
            incomplete.add(identifier)
            continue
        try:
            duration = float(row['duration_seconds'])
            started = datetime.fromisoformat(row['started_at'].replace('Z', '+00:00'))
            if not math.isfinite(duration) or not 0 <= duration <= 1209600 or started.utcoffset() is None:
                raise ValueError('Chronométrage invalide')
            if row['stage'] not in STAGES or row['source'] not in {'winpe', 'windows'}:
                raise ValueError('Étape non reconnue')
            measurements[identifier].append({'stage': row['stage'], 'source': row['source'],
                'duration_seconds': duration, 'start': started.timestamp()})
        except (ValueError, TypeError, OverflowError):
            incomplete.add(identifier)

    stages = defaultdict(list)
    durations = []
    for identifier, key in successes.items():
        items = measurements[identifier]
        by_stage = defaultdict(list)
        for item in items:
            by_stage[item['stage']].append(item)
        for stage, records in by_stage.items():
            stages[stage].append(union_seconds(records))
        # Une image seule ne représente pas la préparation Windows.
        enough = any(x['stage'] == 'image' and x['source'] == 'winpe' for x in items) and any(x['source'] == 'windows' for x in items)
        if items and enough and identifier not in incomplete:
            duration = union_seconds(items)
            durations.append(duration)
            models[key]['durations'].append(duration)
            models[key]['timed_successful'] += 1
            counts['timed_successful'] += 1
        elif items or identifier in incomplete:
            counts['partial_successful'] += 1
        else:
            counts['unmeasured_successful'] += 1

    model_rows = []
    for entry in models.values():
        entry['average_seconds'] = mean(entry.pop('durations'))
        entry['success_rate'] = round(100 * entry['completed'] / entry['finished'], 1)
        model_rows.append(entry)
    model_rows.sort(key=lambda entry: (-entry['finished'], entry['manufacturer'].casefold(), entry['model'].casefold()))
    stage_rows = [{'stage': stage, 'label': STAGES[stage], 'samples': len(values),
                   'average_seconds': mean(values), 'maximum_seconds': round(max(values), 3)}
                  for stage, values in stages.items()]
    stage_rows.sort(key=lambda entry: (-entry['average_seconds'], entry['stage']))
    return {'generated_at': at.isoformat(), 'days': days, 'since': since,
            'summary': {**counts, 'success_rate': round(100 * counts['completed'] / counts['finished'], 1) if counts['finished'] else None,
                        'average_seconds': mean(durations)}, 'models': model_rows, 'stages': stage_rows}


def statistics_routes(api, db, admin, now):
    @api.get('/api/statistics/deployments', dependencies=[Depends(admin)])
    def statistics(days: int = Query(default=30, ge=0, le=3650)):
        with db() as con:
            return deployment_statistics(con, days=days, at=datetime.fromisoformat(now()))
