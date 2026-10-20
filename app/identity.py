"""Stable BIOS serial identities; Ethernet addresses are observations, not keys."""
from collections import Counter, defaultdict
import json
import re

INVALID_SERIALS={'TOBEFILLEDBYOEM','DEFAULTSTRING','SYSTEMSERIALNUMBER','SERIALNUMBER',
                 'NONE','UNKNOWN','NOTAPPLICABLE','NOTSPECIFIED','NOTAVAILABLE','NOTPRESENT','NOTSET','UNSPECIFIED','NA','INVALID','OEM'}


def normalize_serial(value):
    value=' '.join(str(value or '').strip().upper().split())
    compact=re.sub('[^A-Z0-9]','',value)
    if not 4<=len(value)<=80 or not re.fullmatch(r'[A-Z0-9][A-Z0-9 ._-]*',value) or compact in INVALID_SERIALS or not compact or set(compact)<={'0'} or set(compact)<={'F'}:
        raise ValueError('Numero de serie BIOS absent, generique ou invalide')
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
    # executescript in the bootstrap can end the outer transaction. The rename
    # and backfill must still commit together, including after a power loss.
    if not con.in_transaction:con.execute('BEGIN IMMEDIATE')
    if 'serial_number' in {r['name'] for r in con.execute('PRAGMA table_info(machines)')}:return
    # Retain the old UNIQUE column under a private name. Renaming a column keeps
    # machine IDs and all foreign keys intact, unlike replacing the parent table.
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
        # A shared dock may have mixed computers into one old MAC-based history.
        # Never relabel that history, or choose between duplicate old records.
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
        # Existing reports can identify an old record even when it arrived after
        # the schema migration. A MAC alone is never evidence of a serial match.
        serials=defaultdict(set)
        for record in con.execute('SELECT d.machine_id,r.report_json FROM computer_reports r JOIN deployments d ON d.id=r.deployment_id JOIN machines m ON m.id=d.machine_id WHERE m.serial_number IS NULL'):
            value=report_serial(record['report_json'])
            if value:serials[record['machine_id']].add(value)
        matches=[dict(con.execute('SELECT * FROM machines WHERE id=?',(machine,)).fetchone()) for machine,values in serials.items() if values=={serial}]
        if len(matches)==1:
            machine=matches[0];con.execute('UPDATE machines SET serial_number=? WHERE id=?',(serial,machine['id']))
            machine['serial_number']=serial;return machine
        if len(matches)>1:raise ValueError('Plusieurs anciennes fiches portent ce numero de serie ; rapprochement manuel necessaire avant de continuer')
        return None
    records=[dict(r) for r in con.execute('SELECT * FROM machines') if r['mac'] in macs]
    if any(r['serial_number'] for r in records):raise ValueError('Cette interface est utilisee par une fiche avec numero de serie. Demarrer avec le nouveau WinPE IQ-5.0')
    if len(records)>1:raise ValueError('Plusieurs machines correspondent ; utiliser le numero de serie avec WinPE IQ-5.0')
    return records[0] if records else None
