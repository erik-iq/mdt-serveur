"""Résultats définitifs, couverture des mesures et agrégation sans doubles comptes."""
from datetime import datetime, timezone
import json
import sqlite3
import uuid

import pytest

from app.statistics import deployment_statistics
from test_api import auth, prepare, system

AT = datetime(2026, 10, 23, 12, tzinfo=timezone.utc)


def seed(data, machine, profile, *, result='completed', model='EliteBook 840 G5',
         manufacturer='HP', created='2026-10-20T08:00:00Z', report=True,
         state='staged', timing=()):
    identifier = str(uuid.uuid4())
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.execute('''INSERT INTO deployments(id,machine_id,profile_id,disk_number,token_hash,status,
            progress,created_at,updated_at,windows_status) VALUES(?,?,?,0,'fixture',?,100,?,?,?)''',
                    (identifier, machine['id'], profile['id'], state, created, created, result))
        if report:
            con.execute('INSERT INTO computer_reports VALUES(?,?,?)', (identifier, json.dumps({
                'status': result, 'inventory': {'Constructeur': manufacturer, 'Modèle': model}}), created))
        for stage, seconds, start, source, status in timing:
            con.execute('INSERT INTO deployment_timings VALUES(?,?,?,?,?,?,?,?)',
                        (identifier, str(uuid.uuid4()), source, stage, status, start, seconds, created))
    return identifier


def measure(stage, seconds, minute=0, *, source='windows', status='completed'):
    return stage, seconds, f'2026-10-20T09:{minute:02d}:00Z', source, status


def calculate(data, days=30):
    with sqlite3.connect(data/'deployment.sqlite3') as con:
        con.row_factory=sqlite3.Row
        return deployment_statistics(con, days=days, at=AT)


def test_finished_outcomes_and_measured_successes_are_distinct(system):
    client, data = system
    _, machine, profile, _ = prepare(client, data)
    seed(data,machine,profile,timing=[measure('image',120,source='winpe'),measure('software',300,10),measure('hp_updates',600,12)])
    seed(data,machine,profile,model='  elitebook  840 G5 ',manufacturer='hp',timing=[measure('image',60,source='winpe'),measure('software',180,10)])
    seed(data,machine,profile,result='needs_attention',timing=[measure('software',100000)])
    seed(data,machine,profile,result='failed')
    seed(data,machine,profile,state='failed',result=None,report=False)
    seed(data,machine,profile,manufacturer='Dell',model='Latitude')
    seed(data,machine,profile,model='Mesure image seule',timing=[measure('image',50,source='winpe')])
    seed(data,machine,profile,model='Mesure interrompue',timing=[measure('image',10,source='winpe'),measure('software',60,10),measure('hp_updates',0,12,status='running')])
    seed(data,machine,profile,result=None,report=False)
    seed(data,machine,profile,result='completed',report=False)
    seed(data,machine,profile,state='running',result='running',report=False)
    seed(data,machine,profile,state='cancelled')
    result=calculate(data)
    summary=result['summary']
    assert summary['finished']==8 and summary['completed']==5
    assert summary['failed']==2 and summary['needs_attention']==1
    assert summary['success_rate']==62.5
    assert summary['timed_successful']==2 and summary['average_seconds']==540
    assert summary['partial_successful']==2 and summary['unmeasured_successful']==1
    assert summary['excluded_unfinished']==3 and summary['excluded_cancelled']==1
    hp=next(x for x in result['models'] if x['model']=='EliteBook 840 G5')
    assert hp['finished']==4 and hp['success_rate']==50 and hp['average_seconds']==540
    assert hp['timed_successful']==2
    dell=next(x for x in result['models'] if x['manufacturer']=='Dell')
    assert dell['average_seconds'] is None
    unknown=next(x for x in result['models'] if x['model']=='Modèle non transmis')
    assert unknown['failed']==1
    stages={x['stage']:x for x in result['stages']}
    assert result['stages'][0]['stage']=='hp_updates'
    assert stages['hp_updates']['samples']==1 and stages['hp_updates']['average_seconds']==600
    assert stages['software']['samples']==3 and stages['software']['average_seconds']==180
    assert 'token_hash' not in json.dumps(result) and machine['id'] not in json.dumps(result)


def test_period_uses_creation_time_with_timezones_and_all_history_is_not_limited_to_100(system):
    client,data=system
    _,machine,profile,_=prepare(client,data)
    for _ in range(105):seed(data,machine,profile,created='2026-01-01T00:00:00Z')
    seed(data,machine,profile,created='2026-09-23T14:00:00+02:00')
    seed(data,machine,profile,created='2026-09-23T11:59:59Z')
    seed(data,machine,profile,created='2026-10-23T12:00:01Z')
    assert calculate(data)['summary']['finished']==1
    assert calculate(data,0)['summary']['finished']==107
    assert calculate(data,7)['summary']['success_rate'] is None


def test_missing_or_invalid_measurements_never_become_zero_duration(system):
    client,data=system
    _,machine,profile,_=prepare(client,data)
    seed(data,machine,profile,timing=[measure('image',100,source='winpe'),measure('software',-10)])
    result=calculate(data)
    assert result['summary']['average_seconds'] is None
    assert result['summary']['partial_successful']==1
    assert result['stages'][0]['stage']=='image' and len(result['stages'])==1


def test_repeated_passes_are_counted_per_deployment_not_as_extra_samples(system):
    client,data=system
    _,machine,profile,_=prepare(client,data)
    seed(data,machine,profile,timing=[measure('image',100,source='winpe'),measure('hp_updates',60,10),measure('hp_updates',120,15)])
    result=calculate(data)
    assert result['stages'][0]['samples']==1 and result['stages'][0]['average_seconds']==180
    assert result['summary']['average_seconds']==280


def test_statistics_are_admin_only_and_empty_rates_are_not_zero(system):
    client,_=system
    assert client.get('/api/statistics/deployments').status_code==401
    response=client.get('/api/statistics/deployments?days=0',headers=auth())
    assert response.status_code==200,response.text
    assert response.json()['summary']['success_rate'] is None
    assert response.json()['summary']['average_seconds'] is None
    assert response.json()['models']==[] and response.json()['stages']==[]
    assert client.get('/api/statistics/deployments?days=-1',headers=auth()).status_code==422
