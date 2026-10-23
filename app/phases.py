"""Étapes explicitement signalées par les agents, sans déduire des réussites manquantes."""

PHASES = {'image': 'Image Windows', 'hpia': 'HPIA', 'software': 'Logiciels',
          'iq': 'Dossier IQ', 'restart': 'Redémarrage', 'summary': 'Bilan'}
CLOSED = {'completed', 'skipped', 'failed', 'needs_attention'}


def initialize_phases(con):
    con.execute('''CREATE TABLE IF NOT EXISTS deployment_phases(
        deployment_id TEXT NOT NULL REFERENCES deployments(id),stage TEXT NOT NULL,
        status TEXT NOT NULL,started_at TEXT,ended_at TEXT,updated_at TEXT NOT NULL,
        message TEXT NOT NULL,PRIMARY KEY(deployment_id,stage))''')


def record_phase(con, identifier, stage, status, message, timestamp):
    previous = con.execute('SELECT * FROM deployment_phases WHERE deployment_id=? AND stage=?', (identifier, stage)).fetchone()
    if previous and previous['status'] in CLOSED and status in {'running', 'reboot_pending'}:
        return
    started = previous['started_at'] if previous else None
    if not started and status in {'running', 'reboot_pending'}:
        started = timestamp
    ended = ((previous['ended_at'] if previous else None) or timestamp) if status in CLOSED else None
    con.execute('''INSERT INTO deployment_phases VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(deployment_id,stage) DO UPDATE SET status=excluded.status,
        started_at=excluded.started_at,ended_at=excluded.ended_at,updated_at=excluded.updated_at,message=excluded.message''',
        (identifier, stage, status, started, ended, timestamp, message[:1500]))


def public_phases(con, job):
    saved = {r['stage']: dict(r) for r in con.execute('SELECT stage,status,started_at,ended_at,updated_at,message FROM deployment_phases WHERE deployment_id=?', (job['id'],))}
    # Les anciens agents ne fournissent pas toutes les étapes. Seules les preuves exactes sont reprises.
    if 'image' not in saved and job['status'] in {'running', 'staged', 'failed'}:
        first = con.execute("SELECT created_at FROM events WHERE deployment_id=? AND status='running' ORDER BY id LIMIT 1", (job['id'],)).fetchone()
        status = {'running': 'running', 'staged': 'completed', 'failed': 'failed'}[job['status']]
        last = con.execute('SELECT created_at FROM events WHERE deployment_id=? AND status=? ORDER BY id DESC LIMIT 1', (job['id'],job['status'])).fetchone()
        saved['image'] = {'stage':'image','status':status,'started_at':first['created_at'] if first else None,
            'ended_at':last['created_at'] if last and status in CLOSED else None,
            'updated_at':last['created_at'] if last else job['updated_at'],'message':'État de l’image confirmé par le journal WinPE.'}
    report = con.execute('SELECT created_at FROM computer_reports WHERE deployment_id=?', (job['id'],)).fetchone()
    if report and job['windows_status'] in {'completed','failed','needs_attention'}:
        saved['summary'] = {'stage':'summary','status':job['windows_status'],
            'started_at':saved.get('summary',{}).get('started_at'),
            'ended_at':saved.get('summary',{}).get('ended_at') or report['created_at'],
            'updated_at':report['created_at'],'message':'Bilan final reçu sur le serveur.'}
    terminal = job['status'] in {'failed','cancelled'} or (report and job['windows_status'] in CLOSED)
    stages = []
    for stage, label in PHASES.items():
        item = dict(saved.get(stage, {'stage':stage,'status':'unknown' if terminal else 'pending',
            'started_at':None,'ended_at':None,'updated_at':None,
            'message':'Résultat de cette étape non transmis.' if terminal else 'Étape non encore signalée.'}),label=label)
        if terminal and item['status'] in {'running','reboot_pending'}:
            item['status']='unknown'
            item['message']='Fin de cette étape non signalée avant la clôture du déploiement.'
        stages.append(item)
    return {'detailed':any(k not in {'image','summary'} for k in saved),'terminal':bool(terminal),'stages':stages}
