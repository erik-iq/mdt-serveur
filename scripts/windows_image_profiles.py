"""Mise en test et publication transactionnelles des images Windows maintenues."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import uuid


def utcnow():
    return datetime.now(timezone.utc).isoformat()


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def regular_path(path):
    path = Path(path).absolute()
    if any(item.is_symlink() or (hasattr(item, 'is_junction') and item.is_junction()) for item in [path, *path.parents]):
        raise ValueError('Chemin lie interdit')
    return path


@contextmanager
def database(data, write=False):
    path = regular_path(Path(data) / 'deployment.sqlite3')
    if not path.is_file():
        raise ValueError('Base Atelier absente')
    con = sqlite3.connect(path, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA foreign_keys=ON')
    try:
        con.execute('BEGIN IMMEDIATE' if write else 'BEGIN')
        yield con
        con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


def sources(data, asset_id=None):
    with database(data) as con:
        records = con.execute("""SELECT DISTINCT a.* FROM assets a JOIN profiles p ON p.asset_id=a.id
            WHERE a.kind='windows' AND p.archived=0 AND p.edition IN ('Pro','Famille','')
            AND p.id NOT IN (SELECT profile_id FROM windows_image_test_profiles)
            ORDER BY a.filename""").fetchall()
        result = []
        for record in records:
            if asset_id and record['id'] != asset_id:
                continue
            path = regular_path(Path(data) / 'artifacts' / record['filename'])
            if path.parent != regular_path(Path(data) / 'artifacts'):
                raise ValueError('Nom du WIM source invalide')
            result.append(dict(record, path=str(path)))
        if not result:
            raise ValueError('Aucune image Windows utilisée par un profil de production')
        return result


def read_report(data, report_path):
    path = regular_path(report_path)
    root = regular_path(Path(data) / 'windows-servicing' / 'runs')
    if path.name != 'report.json' or path.parent.parent != root:
        raise ValueError('Utiliser un report.json du dossier windows-servicing/runs')
    report = json.loads(path.read_text(encoding='utf-8-sig'))
    candidate = regular_path(report['candidate_path'])
    if candidate != path.parent / 'candidate.wim' or report['status'] != 'ready_for_test':
        raise ValueError('Image non prête pour un test')
    if file_hash(candidate) != report['candidate_sha256']:
        raise ValueError('WIM candidat modifie depuis sa préparation')
    with candidate.open('rb') as stream:
        if stream.read(8) != b'MSWIM\0\0\0':
            raise ValueError('Signature WIM invalide')
    return report


def register_test(data, report_path):
    report = read_report(data, report_path)
    restricted = report.get('scope') == 'home_pro'
    indexes = {}
    for item in report['indexes']:
        original, target = item.get('source_index', item['index']), item['index']
        if (type(original) is not int or type(target) is not int or not 1 <= original <= 100
                or not 1 <= target <= 100 or original in indexes or target in indexes.values()):
            raise ValueError('Correspondance des index invalide')
        indexes[original] = target
    artifacts = regular_path(Path(data) / 'artifacts')
    asset_id = str(uuid.uuid4())
    filename = 'windows-test-' + report['run_id'] + '.wim'
    destination = regular_path(artifacts / filename)
    if destination.parent != artifacts:
        raise ValueError('Identifiant de préparation invalide')
    with database(data) as con:
        existing = con.execute('SELECT * FROM windows_image_candidates WHERE run_id=?', (report['run_id'],)).fetchone()
        if existing:
            return dict(existing)
    temporary = destination.with_suffix('.partial-' + uuid.uuid4().hex)
    installed = False
    try:
        shutil.copyfile(report['candidate_path'], temporary)
        if file_hash(temporary) != report['candidate_sha256']:
            raise ValueError('Copie du WIM de test invalide')
        with database(data, write=True) as con:
            existing = con.execute('SELECT * FROM windows_image_candidates WHERE run_id=?', (report['run_id'],)).fetchone()
            if existing:
                return dict(existing)
            source = con.execute('SELECT * FROM assets WHERE id=? AND kind=\'windows\'', (report['source_asset_id'],)).fetchone()
            if not source or source['sha256'] != report['source_sha256']:
                raise ValueError('Image source remplacée depuis la maintenance')
            profiles = con.execute('SELECT * FROM profiles WHERE archived=0 AND asset_id=? AND id NOT IN (SELECT profile_id FROM windows_image_test_profiles)', (source['id'],)).fetchall()
            if restricted:
                profiles = [p for p in profiles if p['edition'] in ('Pro', 'Famille') or (not p['edition'] and p['image_index'] in indexes)]
            if not profiles or not {p['image_index'] for p in profiles} <= indexes.keys():
                raise ValueError('Index des profils non préparés')
            if destination.exists():
                raise ValueError('Le fichier de test existe déjà sans enregistrement correspondant')
            temporary.replace(destination)
            installed = True
            stat = destination.stat()
            con.execute('INSERT INTO assets VALUES (?,?,?,?,?,?,?)', (asset_id, filename, 'windows',
                report['candidate_sha256'], stat.st_size, stat.st_mtime_ns, utcnow()))
            mappings = []
            # Un profil TEST par profil source préserve l’édition, la langue et
            # tous les réglages. Les profils TEST ne sont jamais choisis automatiquement.
            for profile in profiles:
                test_id = str(uuid.uuid4())
                name = f"TEST {report['run_id']} {test_id[:8]} - {profile['name']}"[:80]
                values = dict(profile, id=test_id, name=name, asset_id=asset_id,
                              image_index=indexes[profile['image_index']], created_at=utcnow())
                columns = list(values)
                con.execute('INSERT INTO profiles (' + ','.join(columns) + ') VALUES (' + ','.join('?' for _ in columns) + ')', [values[k] for k in columns])
                con.execute('INSERT INTO windows_image_test_profiles VALUES (?,?)', (test_id, report['run_id']))
                mappings.append({'source_profile_id': profile['id'], 'test_profile_id': test_id,
                                 'index': indexes[profile['image_index']], 'source_index': profile['image_index'],
                                 'scope': 'home_pro' if restricted else 'all', 'name': name})
            con.execute('INSERT INTO windows_image_candidates VALUES (?,?,?,?,?,?,?,?)',
                (report['run_id'], source['id'], asset_id, source['sha256'], 'testing', json.dumps(mappings), utcnow(), None))
        return {'run_id': report['run_id'], 'asset_id': asset_id, 'status': 'testing', 'test_profiles': mappings}
    except Exception:
        if installed:
            destination.unlink(missing_ok=True)
        raise
    finally:
        temporary.unlink(missing_ok=True)


def promote(data, run_id, deployment_ids):
    # Calculer l’empreinte hors transaction d’écriture et recontrôler l’identité du fichier dedans.
    with database(data) as con:
        candidate = con.execute('SELECT c.*,a.filename,a.sha256 FROM windows_image_candidates c JOIN assets a ON a.id=c.asset_id WHERE c.run_id=?', (run_id,)).fetchone()
        if not candidate:
            raise ValueError('Préparation de test inconnue')
    path = regular_path(Path(data) / 'artifacts' / candidate['filename'])
    before = path.stat()
    if file_hash(path) != candidate['sha256']:
        raise ValueError('Le WIM de test a été modifié')
    with database(data, write=True) as con:
        current = con.execute('SELECT * FROM windows_image_candidates WHERE run_id=?', (run_id,)).fetchone()
        if current['status'] == 'published':
            return {'status': 'published', 'run_id': run_id, 'already_published': True}
        if current['status'] != 'testing':
            raise ValueError('État de validation inattendu')
        if con.execute("SELECT 1 FROM deployments WHERE status IN ('queued','running') LIMIT 1").fetchone():
            raise ValueError('Terminer les déploiements actifs avant la publication')
        mappings = json.loads(current['mappings_json'])
        old_indexes = ','.join(str(int(m.get('source_index',m['index']))) for m in mappings)
        scope = " AND (edition IN ('Pro','Famille') OR (edition='' AND image_index IN ("+old_indexes+")))" if all(m.get('scope') == 'home_pro' for m in mappings) else ''
        production = {p[0] for p in con.execute('SELECT id FROM profiles WHERE archived=0 AND asset_id=? AND id NOT IN (SELECT profile_id FROM windows_image_test_profiles)' + scope, (current['source_asset_id'],))}
        if production != {item['source_profile_id'] for item in mappings}:
            raise ValueError('La liste des profils source a change depuis le test ; publication annulée')
        allowed = {item['test_profile_id']: item['index'] for item in mappings}
        checked = set()
        for identifier in deployment_ids:
            job = con.execute('SELECT * FROM deployments WHERE id=?', (identifier,)).fetchone()
            if not job or job['profile_id'] not in allowed or job['status'] != 'staged' or job['windows_status'] != 'completed':
                raise ValueError('Chaque preuve doit être un déploiement de cette image avec préparation Windows terminée sans avertissement')
            checked.add(allowed[job['profile_id']])
        if checked != {item['index'] for item in mappings}:
            raise ValueError('Un déploiement Windows réussi est requis pour chaque index utilise (Pro/Famille)')
        source = con.execute('SELECT sha256 FROM assets WHERE id=?', (current['source_asset_id'],)).fetchone()
        if not source or source['sha256'] != current['source_sha256']:
            raise ValueError('Image source modifiée depuis le test')
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError('Le WIM de test est en cours de modification')
        for item in mappings:
            changed = con.execute('UPDATE profiles SET asset_id=?,image_index=? WHERE id=? AND asset_id=? AND image_index=?',
                (current['asset_id'], item['index'], item['source_profile_id'], current['source_asset_id'], item.get('source_index', item['index']))).rowcount
            if changed != 1:
                raise ValueError('Un profil source a change depuis le test ; publication annulée')
        con.execute("UPDATE windows_image_candidates SET status='published',published_at=? WHERE run_id=?", (utcnow(), run_id))
    return {'status': 'published', 'run_id': run_id, 'asset_id': current['asset_id'], 'test_deployments': deployment_ids}


def status(data, run_id=None):
    with database(data) as con:
        runs = con.execute('SELECT * FROM windows_image_candidates ORDER BY created_at DESC').fetchall()
        result = []
        for run in runs:
            if run_id and run['run_id'] != run_id:
                continue
            jobs = [dict(job) for job in con.execute('''SELECT d.id,d.profile_id,p.name,d.status,d.windows_status,d.created_at
                FROM deployments d JOIN profiles p ON p.id=d.profile_id
                JOIN windows_image_test_profiles t ON t.profile_id=p.id WHERE t.run_id=? ORDER BY d.created_at DESC''', (run['run_id'],))]
            result.append(dict(run_id=run['run_id'], status=run['status'], profiles=json.loads(run['mappings_json']), test_deployments=jobs))
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('sources').add_argument('--asset-id')
    sub.add_parser('register-test').add_argument('--report', required=True)
    sub.add_parser('status').add_argument('--run-id')
    pub = sub.add_parser('promote')
    pub.add_argument('--run-id', required=True)
    pub.add_argument('--deployment-id', action='append', required=True)
    args = parser.parse_args()
    if args.command == 'sources':
        result = sources(args.data, args.asset_id)
    elif args.command == 'register-test':
        result = register_test(args.data, args.report)
    elif args.command == 'status':
        result = status(args.data, args.run_id)
    else:
        result = promote(args.data, args.run_id, args.deployment_id)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
