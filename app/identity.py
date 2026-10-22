"""Identité stable par numéro BIOS ; les adresses Ethernet restent des observations."""
from collections import Counter, defaultdict
import json
import re

INVALID_SERIALS={'TOBEFILLEDBYOEM','DEFAULTSTRING','SYSTEMSERIALNUMBER','SERIALNUMBER',
                 'NONE','UNKNOWN','NOTAPPLICABLE','NOTSPECIFIED','NOTAVAILABLE','NOTPRESENT','NOTSET','UNSPECIFIED','NA','INVALID','OEM'}


def normalize_serial(value):
    value=' '.join(str(value or '').strip().upper().split())
    compact=re.sub('[^A-Z0-9]','',value)
    if not 4<=len(value)<=80 or not re.fullmatch(r'[A-Z0-9][A-Z0-9 ._-]*',value) or compact in INVALID_SERIALS or not compact or set(compact)<={'0'} or set(compact)<={'F'}:
        raise ValueError('Numéro de série BIOS absent, générique ou invalide')
    return value


def normalize_mac(value):
    value=value.replace('-',':').upper()
    if not re.fullmatch(r'[0-9A-F]{2}(:[0-9A-F]{2}){5}',value) or int(value[:2],16)&1 or value=='00:00:00:00:00:00':
        raise ValueError('Adresse MAC unicast invalide')
    return value


def report_serial(report):
    try:return normalize_serial(json.loads(report).get('inventory',{}).get('Numero de serie',''))
    except (ValueError,TypeError,AttributeError):return None


def migrate_identity(con):
    columns={r['name'] for r in con.execute('PRAGMA table_info(machines)')}
    if 'serial_number' in columns:return
    # executescript peut terminer la transaction extérieure pendant l’initialisation.
    # Le renommage et la reprise des données doivent rester atomiques, même en cas de coupure.
    if not con.in_transaction:con.execute('BEGIN IMMEDIATE')
    if 'serial_number' in {r['name'] for r in con.execute('PRAGMA table_info(machines)')}:return
    # Conserver l’ancienne colonne UNIQUE sous un nom privé. Son renommage préserve
    # les identifiants des machines et leurs clés étrangères, sans remplacer la table parente.
    con.execute('ALTER TABLE machines RENAME COLUMN mac TO legacy_mac_key')
    con.execute("ALTER TABLE machines ADD COLUMN mac TEXT NOT NULL DEFAULT ''")
    con.execute('UPDATE machines SET mac=legacy_mac_key')
    con.execute('ALTER TABLE machines ADD COLUMN serial_number TEXT')
    con.execute('CREATE UNIQUE INDEX machine_serial_unique ON machines(serial_number) WHERE serial_number IS NOT NULL')
    con.execute('CREATE INDEX machine_mac_observation ON machines(mac)')
    serials=defaultdict(set)
    for record in con.execute('SELECT d.machine_id,r.report_json FROM computer_reports r JOIN deployments d ON d.id=r.deployment_id'):
        serial=report_serial(record['report_json'])
        if serial:serials[record['machine_id']].add(serial)
    counts=Counter(s for values in serials.values() for s in values)
    for machine,values in serials.items():
        # Une station d’accueil partagée peut avoir regroupé plusieurs PC dans un historique MAC.
        # Ne jamais réattribuer cet historique ni départager arbitrairement les doublons.
        if len(values)==1:
            serial=next(iter(values))
            if counts[serial]==1:con.execute('UPDATE machines SET serial_number=? WHERE id=?',(serial,machine))


def public_machine(record):
    result=dict(record);result.pop('legacy_mac_key',None)
    return result


def insert_machine(con,identifier,hostname,mac,description,created,serial=''):
    con.execute('INSERT INTO machines(id,hostname,legacy_mac_key,mac,description,created_at,serial_number) VALUES(?,?,?,?,?,?,?)',
                (identifier,hostname,'machine:'+identifier,mac,description,created,serial or None))


def match_machine(con,serial,macs):
    if serial:
        record=con.execute('SELECT * FROM machines WHERE serial_number=?',(serial,)).fetchone()
        if record:return dict(record)
        # Les rapports existants peuvent identifier une ancienne fiche après la migration.
        # Une adresse MAC seule ne prouve jamais la correspondance d’un numéro de série.
        serials=defaultdict(set)
        for record in con.execute('SELECT d.machine_id,r.report_json FROM computer_reports r JOIN deployments d ON d.id=r.deployment_id JOIN machines m ON m.id=d.machine_id WHERE m.serial_number IS NULL'):
            value=report_serial(record['report_json'])
            if value:serials[record['machine_id']].add(value)
        matches=[dict(con.execute('SELECT * FROM machines WHERE id=?',(machine,)).fetchone()) for machine,values in serials.items() if values=={serial}]
        if len(matches)==1:
            machine=matches[0];con.execute('UPDATE machines SET serial_number=? WHERE id=?',(serial,machine['id']))
            machine['serial_number']=serial;return machine
        if len(matches)>1:raise ValueError('Plusieurs anciennes fiches portent ce numéro de série ; rapprochement manuel nécessaire avant de continuer')
        return None
    records=[dict(r) for r in con.execute('SELECT * FROM machines') if r['mac'] in macs]
    if any(r['serial_number'] for r in records):raise ValueError('Cette interface est utilisée par une fiche avec numéro de série. Démarrer avec le nouveau WinPE IQ-5.0')
    if len(records)>1:raise ValueError('Plusieurs machines correspondent ; utiliser le numéro de série avec WinPE IQ-5.0')
    return records[0] if records else None
