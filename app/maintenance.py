"""Suivi de maintenance authentifié. Consulter une image ne la monte et ne la modifie jamais."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import threading
import time
import zipfile

from fastapi import BackgroundTasks, Depends, HTTPException
from fastapi.responses import JSONResponse

from scripts.windows_update_catalog import select_plan

RUN = re.compile(r'[0-9]{8}-[0-9]{6}-[a-f0-9]{8}')


def checked(data, path):
    if not path.resolve().is_relative_to(data.resolve()) or any(
            p.is_symlink() or getattr(p, 'is_junction', lambda: False)() for p in [path, *path.parents]):
        raise HTTPException(409, 'Chemin de suivi non autorisé')
    return path


def read_json(data, path):
    checked(data, path)
    with path.open('rb') as stream:
        raw = stream.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError('Fichier de suivi trop volumineux')
    return json.loads(raw.decode('utf-8-sig'))


def footprint(data, path):
    checked(data, path)
    total = count = 0
    pending = [path]
    deadline = time.monotonic() + 2
    complete = True
    while pending:
        if count >= 50000 or time.monotonic() > deadline:
            complete = False
            break
        folder = pending.pop()
        try:
            with os.scandir(folder) as entries:
                for item in entries:
                    if item.is_symlink() or getattr(Path(item.path), 'is_junction', lambda: False)():
                        continue
                    if item.is_dir(follow_symlinks=False):
                        if item.name.casefold() != 'mount': pending.append(Path(item.path))
                    elif item.is_file(follow_symlinks=False):
                        total += item.stat(follow_symlinks=False).st_size
                        count += 1
        except FileNotFoundError:
            pass
        except PermissionError:
            complete = False
    return {'bytes': total, 'files': count, 'complete': complete}


def public_report(report):
    if not isinstance(report, dict): raise ValueError('Rapport invalide')
    fields = ('schema','layout','scope','compression','run_id','status','source_asset_id','source_path',
              'source_sha256','backup_path','candidate_path','started_at','finished_at','updated_at',
              'active_stage','active_index','progress_text','error','candidate_sha256')
    result = {k: report.get(k) for k in fields}
    result['selected_indexes'] = report.get('selected_indexes', [])[:100]
    result['skipped_indexes'] = report.get('skipped_indexes', [])[:100]
    result['timings'] = report.get('timings', [])[-500:]
    result['indexes'] = []
    for entry in report.get('indexes', [])[:100]:
        item = {k: entry.get(k) for k in ('index','source_index','name','edition','version','architecture','package_count')}
        item['updates'] = []
        for update in entry.get('updates', [])[:20]:
            group = {k:update.get(k) for k in ('kind','update_id','kb','title','exit_code','target_build')}
            group['files'] = [{k:f.get(k) for k in ('filename','size','sha256')} for f in update.get('files', [])[:100]]
            item['updates'].append(group)
        result['indexes'].append(item)
    return result


class Maintenance:
    def __init__(self, data, db, hp):
        self.data, self.db, self.hp = data, db, hp
        self.public = data / 'maintenance-overview'
        self.cache = {}
        self.check_lock = threading.Lock()

    def storage(self):
        now = time.monotonic()
        if 'storage' in self.cache and now - self.cache['storage'][0] < 20:
            return self.cache['storage'][1]
        volumes = []
        roots = {self.data.resolve().anchor}
        if os.name == 'nt': roots.add(Path(os.environ.get('SystemRoot', 'C:\\Windows')).anchor)
        for root in sorted(roots):
            try:
                usage = shutil.disk_usage(root)
                volumes.append({'root':root,'total':usage.total,'used':usage.used,'free':usage.free})
            except OSError: pass
        categories = []
        for name, folder in [('Pilotes HP','hp-repository'),('Images et fichiers','artifacts'),('Inventaires','inventaires'),('Correctifs Windows des postes','windows-kb')]:
            categories.append({'name':name, **footprint(self.data, self.data / folder)})
        try:
            private = read_json(self.data, self.public / 'status.json')
            names = {'backups':'Sauvegardes WIM','packages':'Correctifs Microsoft en cache','runs':'Candidates et journaux WIM (hors montages)'}
            for item in private.get('storage', []):
                categories.append({**item, 'name':names.get(item['name'],item['name']), 'measured_at':private.get('generated_at')})
        except (OSError, ValueError): pass
        result = {'generated_at':datetime.now(timezone.utc).isoformat(),'volumes':volumes,'categories':categories,
                  'note':'Tailles logiques des fichiers Atelier. Les autres données du volume et les montages Windows ne sont pas inclus dans ces catégories.'}
        self.cache['storage'] = now, result
        return result

    def hp_status(self):
        now = time.monotonic()
        if 'hp' in self.cache and now - self.cache['hp'][0] < 15: return self.cache['hp'][1]
        with self.db() as con:
            status = self.hp.state(con)
            snapshots = [dict(r) for r in con.execute('SELECT * FROM hp_repository_snapshots ORDER BY created_at DESC')]
            requests = [dict(r) for r in con.execute('''SELECT q.platform,q.os,q.os_version,q.required_json,d.machine_id,
                COALESCE(json_extract(r.report_json,'$.inventory.Modèle'),json_extract(r.report_json,'$.inventory.Modele')) AS model,
                json_extract(r.report_json,'$.inventory."Source des pilotes HP"') AS hp_source FROM hp_repository_requests q
                JOIN deployments d ON d.id=q.deployment_id LEFT JOIN computer_reports r ON r.deployment_id=d.id''')]
        models = {}
        for item in [*requests, *snapshots]:
            key = (item['platform'],item['os'],item['os_version'])
            model = models.setdefault(key, {'platform':key[0],'os':key[1],'os_version':key[2],
                'names':set(),'machines':set(),'required':set(),'packages':[],'snapshot':None,'issues':[],'reported_sources':set(),'cache':{'status':'missing','message':'Aucune copie publiée.'}})
            if item.get('model'): model['names'].add(item['model'])
            if item.get('hp_source'): model['reported_sources'].add(item['hp_source'])
            if item.get('machine_id'): model['machines'].add(item['machine_id'])
            if item.get('required_json'): model['required'].update(json.loads(item['required_json']))
        seen = set()
        for snapshot in snapshots:
            key = (snapshot['platform'],snapshot['os'],snapshot['os_version'])
            if key in seen: continue
            seen.add(key);model=models[key]
            model['cache']=self.hp.cache_status(snapshot)
            model['snapshot'] = {k:snapshot[k] for k in ('id','created_at','size','sha256')}
            path = self.hp.checked(self.hp.root / 'snapshots' / (snapshot['id']+'.zip'))
            try:
                if not path.is_file() or path.stat().st_size != snapshot['size']:
                    raise ValueError('Archive serveur absente ou taille modifiée')
                signature=(path.stat().st_size,path.stat().st_mtime_ns)
                cache_key='snapshot:'+snapshot['id']
                cached=self.cache.get(cache_key)
                if cached and cached[0]==signature:
                    model['packages']=list(cached[1]);continue
                with zipfile.ZipFile(path) as archive:
                    entries = archive.infolist()
                    if len(entries)>5000: raise ValueError('Archive trop volumineuse pour le suivi')
                    for entry in entries:
                        if not re.fullmatch(r'sp[0-9]{4,8}\.exe',entry.filename,re.I): continue
                        package = {'id':Path(entry.filename).stem.upper(),'filename':entry.filename,'size':entry.file_size,
                                   'title':None,'version':None,'stored':True}
                        cva=next((e for e in entries if e.filename.casefold()==str(Path(entry.filename).with_suffix('.cva')).casefold()),None)
                        if cva and cva.file_size<=256*1024:
                            raw=archive.read(cva)
                            encoding='utf-16' if raw.startswith((b'\xff\xfe',b'\xfe\xff')) else ('utf-16-le' if b'\x00' in raw[:200] else 'utf-8-sig')
                            text=raw.decode(encoding,errors='replace')
                            version=re.search(r'(?im)^\s*Version\s*=\s*(.+)$',text)
                            title=re.search(r'(?im)^\s*(?:Title|SoftwareTitle)\s*=\s*(.+)$',text)
                            if not title: title=re.search(r'(?im)\[Software Title\]\s*\n\s*US\s*=\s*(.+)$',text)
                            package['version']=version[1].strip()[:150] if version else None
                            package['title']=title[1].strip()[:300] if title else None
                        model['packages'].append(package)
                self.cache[cache_key]=signature,list(model['packages'])
            except (OSError, ValueError, zipfile.BadZipFile) as exc:
                model['issues'].append(str(exc))
                model['cache']={'status':'unavailable','message':'Archive absente, illisible ou taille différente ; utilisation non confirmée.'}
        for key, model in models.items():
            model['reported_sources']=sorted(model['reported_sources'])
            model['names']=sorted(model['names']);model['machine_count']=len(model.pop('machines'))
            model['required']=sorted(model['required']);model['packages'].sort(key=lambda p:p['id'])
            model['missing']=sorted(set(model['required'])-{p['id'] for p in model['packages']})
            model['latest_job']=next((j for j in status['jobs'] if (j['platform'],j['os'],j['os_version'])==key),None)
        result = {**status,'models':list(models.values())}
        self.cache['hp']=now,result
        return result

    def windows_status(self):
        try: worker = read_json(self.data, self.public / 'status.json')
        except (OSError, ValueError): worker = {'task_state':'Unknown','generated_at':None,'message':'Suivi serveur pas encore publié'}
        reports = []
        folder=checked(self.data,self.public/'runs')
        if folder.exists():
            for path in sorted(folder.glob('*.json'),reverse=True)[:100]:
                if not RUN.fullmatch(path.stem): continue
                try:
                    record=read_json(self.data,path)
                    if record.get('run_id')==path.stem: reports.append(public_report(record))
                except (OSError,ValueError,TypeError,KeyError): continue
        with self.db() as con:
            images = [dict(r) for r in con.execute('''SELECT DISTINCT a.id,a.filename,a.sha256,a.size FROM assets a
                JOIN profiles p ON p.asset_id=a.id WHERE a.kind='windows' AND p.edition IN ('Pro','Famille','')
                AND p.id NOT IN (SELECT profile_id FROM windows_image_test_profiles) ORDER BY a.filename''')]
            candidates = {r['run_id']:dict(r) for r in con.execute('SELECT run_id,status,asset_id,created_at,published_at FROM windows_image_candidates')}
        for report in reports:
            report['validation']=candidates.get(report['run_id'])
            report['candidate_file']=next((f for f in worker.get('candidates',[]) if f['run_id']==report['run_id']),None)
            report['download_url']='/api/maintenance/windows/runs/'+str(report['run_id'])+'/report'
            script=Path(__file__).resolve().parents[1]/'scripts'/'Update-WindowsImage.ps1'
            private_report=self.data/'windows-servicing'/'runs'/str(report['run_id'])/'report.json'
            report['register_test_command']="& '"+str(script).replace("'","''")+"' -Mode RegisterTest -ReportPath '"+str(private_report).replace("'","''")+"'"
        try: latest_check=read_json(self.data,self.public/'catalog-check.json')
        except (OSError,ValueError): latest_check={'status':'not_checked','contexts':[]}
        if latest_check.get('status')=='running' and not self.check_lock.locked():
            latest_check={**latest_check,'status':'interrupted','message':'Vérification précédente interrompue ; vous pouvez la relancer.'}
        return {'worker':worker,'images':images,'reports':reports,'catalog_check':latest_check}

    def check_catalog(self):
        try:
            state=self.windows_status();contexts={};deadline=time.monotonic()+90
            for report in state['reports']:
                for entry in report['indexes']:
                    version=entry.get('version') or {};arch=entry.get('architecture');net=version.get('dotnet') or ''
                    family=version.get('family');release=version.get('release')
                    if family not in ('10','11') or not re.fullmatch(r'[12][0-9]H[12]',str(release)) or arch not in ('x64','arm64') or net not in ('','4.8','4.8.1'): continue
                    key=(family,release,arch,net)
                    if key not in contexts:
                        known=[{k:g.get(k) for k in ('kind','update_id','kb','target_build')} for g in entry['updates']]
                        remaining=deadline-time.monotonic()
                        if remaining<=0: raise TimeoutError('Recherche arrêtée après 90 secondes ; aucun correctif installe')
                        plan=select_plan(*key,timeout_seconds=remaining)
                        latest=[{k:g.get(k) for k in ('kind','id','kb','title','published','target_build')} for g in plan['groups']]
                        for g in latest:
                            g['new']=not any(old['kind']==g['kind'] and old['kb']==g['kb'] and
                                (old['update_id']==g['id'] if old['update_id'] else old['target_build']==g['target_build']) for old in known)
                        contexts[key]={'family':family,'release':release,'architecture':arch,'dotnet':net,'groups':latest,'compared_run':report['run_id']}
            self.write_check({'status':'completed','checked_at':datetime.now(timezone.utc).isoformat(),'contexts':list(contexts.values())})
        except Exception as exc:
            self.write_check({'status':'failed','checked_at':datetime.now(timezone.utc).isoformat(),'message':str(exc)[:1500],'contexts':[]})
        finally: self.check_lock.release()

    def write_check(self,value):
        checked(self.data,self.public).mkdir(exist_ok=True)
        path=checked(self.data,self.public/'catalog-check.json');temporary=path.with_suffix('.tmp')
        checked(self.data,temporary).write_text(json.dumps(value),encoding='utf-8');os.replace(temporary,path)

    def routes(self,api,admin):
        @api.get('/api/maintenance/storage',dependencies=[Depends(admin)])
        def storage_status():
            return self.storage()

        @api.get('/api/maintenance/hp',dependencies=[Depends(admin)])
        def hp_status(fresh:bool=False):
            if fresh: self.cache.pop('hp',None);self.cache.pop('storage',None)
            return self.hp_status()

        @api.get('/api/maintenance/windows',dependencies=[Depends(admin)])
        def windows_status(fresh:bool=False):
            if fresh: self.cache.pop('storage',None)
            return self.windows_status()

        @api.post('/api/maintenance/windows/check',dependencies=[Depends(admin)],status_code=202)
        def check(background:BackgroundTasks):
            if not self.check_lock.acquire(blocking=False): raise HTTPException(409,'Vérification du catalogue déjà en cours')
            try:
                self.write_check({'status':'running','checked_at':datetime.now(timezone.utc).isoformat(),'contexts':[]})
                background.add_task(self.check_catalog)
            except Exception:
                self.check_lock.release();raise
            return {'accepted':True,'message':'Vérification des KB uniquement ; aucun MSU téléchargé et aucun DISM lancé'}

        @api.get('/api/maintenance/windows/runs/{identifier}/report',dependencies=[Depends(admin)])
        def report(identifier:str):
            if not RUN.fullmatch(identifier): raise HTTPException(404,'Préparation inconnue')
            try:
                result=public_report(read_json(self.data,self.public/'runs'/(identifier+'.json')))
                if result['run_id']!=identifier: raise ValueError('Identifiant du rapport incorrect')
            except (OSError,ValueError): raise HTTPException(404,'Rapport non disponible')
            return JSONResponse(result,headers={'Content-Disposition':'attachment; filename="maintenance-'+identifier+'.json"'})
