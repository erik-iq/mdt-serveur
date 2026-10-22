'use strict';
const maintenanceDate=value=>value?date(value):'Non transmis';
const maintenanceBytes=value=>Number.isFinite(value)?size(value):'Non transmis';
const maintenanceStates={preparing:'Preparation en cours',ready_for_test:'Candidate a tester',cancelled_cleanup_required:'Annulee - montage a recuperer',failed_cleanup_required:'Echec - montage a recuperer',testing:'Tests en cours',published:'Publiee',Ready:'Au repos',Running:'En cours',Disabled:'En pause',Unknown:'Etat non transmis',NotConfigured:'Non planifiee',not_checked:'Recherche non lancee'};
const maintenanceLabel=value=>maintenanceStates[value]||labels[value]||value||'Non transmis';
const maintenanceDuration=value=>Number.isFinite(value)?`${Math.floor(value/60)} min ${Math.round(value%60)} s`:'Non mesure';
let maintenanceLoading=false;

function maintenanceStorage(value){
  return `<div class="metrics">${value.volumes.map(v=>`<article><span>Volume ${esc(v.root)}</span><strong>${maintenanceBytes(v.free)}</strong><small>libres sur ${maintenanceBytes(v.total)}</small><progress class="maintenance-capacity" max="100" value="${Math.round(100*v.used/v.total)}" aria-label="Occupation du volume ${esc(v.root)}"></progress><small>${maintenanceBytes(v.used)} utilises</small></article>`).join('')}</div><details class="panel padding"><summary>Repartition du stockage Atelier</summary><p>${esc(value.note)} Mesure : ${maintenanceDate(value.generated_at)}.</p><div class="table-wrap"><table><thead><tr><th>CATEGORIE</th><th>TAILLE</th><th>FICHIERS</th><th>MESURE</th></tr></thead><tbody>${value.categories.map(c=>`<tr><td>${esc(c.name)}</td><td>${maintenanceBytes(c.bytes)}${c.complete?'':' (partiel)'}</td><td>${esc(c.files)}</td><td>${maintenanceDate(c.measured_at||value.generated_at)}</td></tr>`).join('')}</tbody></table></div></details>`;
}

function maintenanceReplace(id,html){
  const opened=new Set([...$(id).querySelectorAll('details[open][data-maint-key]')].map(d=>d.dataset.maintKey));
  $(id).innerHTML=html;
  $(id).querySelectorAll('details[data-maint-key]').forEach(d=>{if(opened.has(d.dataset.maintKey))d.open=true;});
}

function filterHpMaintenance(){
  const query=$('hp-maintenance-search').value.trim().toLowerCase();
  $('hp-maintenance-models').querySelectorAll('[data-hp-search]').forEach(card=>card.hidden=!!query&&!card.dataset.hpSearch.includes(query));
}

function renderHpMaintenance(value){
  $('hp-maintenance-storage').innerHTML=maintenanceStorage(value.storage);
  $('hp-maintenance-message').textContent=`Agent : ${maintenanceLabel(value.worker.state)}. ${value.worker.message} Dernier contact : ${maintenanceDate(value.worker.last_seen)}.`;
  maintenanceReplace('hp-maintenance-models',value.models.map(m=>{
    const search=[...m.names,m.platform,...m.packages.flatMap(p=>[p.id,p.title||'',p.version||''])].join(' ').toLowerCase();
    return `<article class="panel padding maintenance-card" data-hp-search="${esc(search)}"><div class="section-title"><div><h3>${esc(m.names.join(' / ')||'Modele non encore transmis')}</h3><p>Plateforme ${esc(m.platform)} | ${esc(m.os)} ${esc(m.os_version)} | ${m.machine_count} poste(s)</p></div>${badge(m.latest_job?.status||(m.snapshot?'completed':'not_ready'))}</div><p>${m.snapshot?`${m.packages.length} SoftPaq dans la derniere archive (${maintenanceBytes(m.snapshot.size)}), publiee le ${maintenanceDate(m.snapshot.created_at)}.`:'Aucune archive disponible sur le serveur pour cette plateforme.'}</p>${m.latest_job?`<p>${esc(m.latest_job.message)}</p>`:''}${m.issues.map(i=>`<p class="form-error">${esc(i)}</p>`).join('')}<p>${!m.required.length?'Aucune liste de SoftPaq attendus transmise.':m.missing.length?'SoftPaq demandes encore absents : '+esc(m.missing.join(', ')):'Tous les SoftPaq demandes sont presents dans la liste du cache.'}</p><details data-maint-key="hp-${esc(m.platform+'-'+m.os_version)}"><summary>Pilotes et logiciels stockes (${m.packages.length})</summary><p>Presence et taille de l archive controlees. Le tableau ne recalcule pas les empreintes de plusieurs Go a chaque ouverture.</p><div class="table-wrap"><table><thead><tr><th>SOFTPAQ</th><th>DESCRIPTION</th><th>VERSION CVA</th><th>TAILLE EXE</th></tr></thead><tbody>${m.packages.map(p=>`<tr><td>${esc(p.id)}<small>${esc(p.filename)}</small></td><td>${esc(p.title||'Description non renseignee')}</td><td>${esc(p.version||'Non renseignee')}</td><td>${maintenanceBytes(p.size)}</td></tr>`).join('')}</tbody></table></div></details></article>`;
  }).join('')||'<div class="panel padding"><h3>Aucun modele HP connu</h3><p>Un poste avec HPIA selectionne transmet sa plateforme et ses recommandations pendant la preparation.</p></div>');
  $('hp-maintenance-history').innerHTML=`<div class="panel table-wrap"><table><thead><tr><th>PLATEFORME</th><th>WINDOWS</th><th>ETAT</th><th>DETAIL</th><th>ACTUALISE LE</th></tr></thead><tbody>${value.jobs.map(j=>`<tr><td>${esc(j.platform)}</td><td>${esc(j.os)} ${esc(j.os_version)}</td><td>${badge(j.status)}</td><td>${esc(j.message)}</td><td>${maintenanceDate(j.updated_at)}</td></tr>`).join('')}</tbody></table></div>`;
  filterHpMaintenance();
}

function servicingStage(value){
  const stages={backup:'Sauvegarde de l original',export_fast:'Export en compression rapide',mount:'Montage de l edition',catalog_download:'Catalogue et telechargement des MSU',commit:'Enregistrement et verification du WIM',verify_hash:'Verification finale SHA-256',ready_for_test:'Candidate prete pour les tests'};
  return stages[value]||(value?.startsWith('integrate_')?'Integration '+value.slice(10):value)||'Etape non transmise';
}

function renderWindowsMaintenance(value){
  $('windows-maintenance-storage').innerHTML=maintenanceStorage(value.storage);
  const worker=value.worker;
  $('windows-maintenance-source').innerHTML=`<h3>Tache serveur : ${esc(maintenanceLabel(worker.task_state))}</h3><p>Derniere mesure : ${maintenanceDate(worker.generated_at)} | Dernier lancement : ${maintenanceDate(worker.last_run)} | Resultat : ${esc(worker.last_result??'Non transmis')}</p><p>La planification configuree par Atelier est mensuelle, le 15 a 02:00 (heure du serveur). Une tache en pause reste en pause. Les donnees sont publiees par l agent serveur ; une ancienne mesure ne prouve pas une activite actuelle.</p>${value.images.map(i=>`<p><strong>${esc(i.filename)}</strong> - ${maintenanceBytes(i.size)}<br><span class="hash">SHA-256 ${esc(i.sha256)}</span></p>`).join('')||'<p>Aucun WIM utilise par un profil Famille ou Pro.</p>'}`;
  const check=value.catalog_check;
  $('windows-maintenance-check').disabled=check.status==='running';
  $('windows-maintenance-catalog').innerHTML=`<p>${esc(maintenanceLabel(check.status))} | ${maintenanceDate(check.checked_at)}</p>${check.message?`<p class="form-error">${esc(check.message)}</p>`:''}${check.contexts.map(c=>`<h3>Windows ${esc(c.family)} ${esc(c.release)} ${esc(c.architecture)}${c.dotnet?' - .NET '+esc(c.dotnet):''}</h3><p>Compare au passage ${esc(c.compared_run)}. Ce controle ne certifie pas que la KB est publiee en production.</p>${c.groups.map(g=>`<p><b>${esc(g.kb)}</b> ${g.new?'<span class="badge queued">Nouveau correctif</span>':'<span class="badge">Deja observe</span>'} ${esc(g.title)}<br>Publication Microsoft : ${esc(g.published)}${g.target_build?' | Build '+esc(g.target_build):''}</p>`).join('')}`).join('')}${!check.contexts.length?'<p>Les versions detectees dans une preparation WIM sont necessaires pour rechercher les correctifs compatibles. Aucun telechargement MSU ni DISM n est lance par ce bouton.</p>':''}`;
  maintenanceReplace('windows-maintenance-runs',value.reports.map(r=>`<article class="panel padding maintenance-card"><div class="section-title"><div><h3>${esc(r.source_path?.split(/[\\/]/).pop()||r.run_id)}</h3><p>Execution ${esc(r.run_id)} | ${maintenanceDate(r.started_at)}</p></div><span class="badge ${esc(r.status)}">${esc(maintenanceLabel(r.status))}</span></div><h3>${esc(servicingStage(r.active_stage))}${r.active_index?' - index '+esc(r.active_index):''}</h3><p>Derniere information : ${maintenanceDate(r.updated_at||r.finished_at||r.started_at)}. ${esc(r.progress_text||'')}</p>${r.error?`<p class="form-error">${esc(r.error)}</p>`:''}<p>${r.layout==='home_pro_fast_v1'?'WIM reduit Famille/Pro | compression fast':'Ancienne preparation - image non reduite'} | Validation : ${esc(r.validation?maintenanceLabel(r.validation.status):'Non enregistree pour test')}</p><div class="actions"><button class="button secondary" data-inventory-file="${esc(r.download_url)}" data-filename="maintenance-${esc(r.run_id)}.json">Telecharger le rapport JSON</button>${r.status==='ready_for_test'&&!r.validation&&r.candidate_file?.present!==false?`<button class="button secondary" data-maint-command="${esc(r.register_test_command)}">Copier la commande de mise en test</button>`:''}</div><details data-maint-key="wim-${esc(r.run_id)}"><summary>Editions, correctifs et durees detaillees</summary><div class="table-wrap"><table><thead><tr><th>EDITION</th><th>INDEX SOURCE &rarr; CANDIDAT</th><th>CORRECTIFS INTEGRES</th></tr></thead><tbody>${r.indexes.map(i=>`<tr><td>${esc(i.name||i.edition)}</td><td>${esc(i.source_index??i.index)} &rarr; ${esc(i.index)}</td><td>${i.updates.map(g=>`${esc(g.kb)} (${esc(g.exit_code)})<small>${esc(g.title)}</small>`).join('')}</td></tr>`).join('')}</tbody></table></div><h3>Durees mesurees par etape</h3>${r.timings.length?`<div class="table-wrap"><table><thead><tr><th>ETAPE</th><th>INDEX</th><th>DUREE</th><th>ETAT</th></tr></thead><tbody>${r.timings.map(t=>`<tr><td>${esc(servicingStage(t.stage))}</td><td>${esc(t.index||'-')}</td><td>${maintenanceDuration(t.duration_seconds)}</td><td>${badge(t.status)}</td></tr>`).join('')}</tbody></table></div>`:'<p>Cette ancienne execution ne mesure pas les etapes.</p>'}<p>Candidate : ${esc(r.candidate_path)}${r.candidate_file?' | '+(r.candidate_file.present?maintenanceBytes(r.candidate_file.size):'Fichier absent'):''}<br>Sauvegarde : ${esc(r.backup_path)}</p><p>La production est conservee tant que les deploiements de test requis ne sont pas termines avec succes.</p></details></article>`).join('')||'<div class="panel padding"><p>Aucune preparation publiee dans le suivi. Le prochain passage de l agent transmettra les rapports existants.</p></div>');
}

async function loadMaintenance(page,fresh=false){
  if(maintenanceLoading||(!sessionReady))return;
  maintenanceLoading=true;
  const hp=page==='hp-maintenance';const message=$(hp?'hp-maintenance-message':'windows-maintenance-message');
  try{
    const value=await api('/maintenance/'+(hp?'hp':'windows')+(fresh?'?fresh=true':''));
    if(hp)renderHpMaintenance(value);else{renderWindowsMaintenance(value);message.textContent='Suivi actualise. Les donnees privees de montage ne sont pas exposees par le site.';}
  }catch(error){message.textContent=error.message;}
  finally{maintenanceLoading=false;}
}

document.addEventListener('click',async event=>{
  const nav=event.target.closest('[data-page]');
  if(nav&&['hp-maintenance','windows-maintenance'].includes(nav.dataset.page))await loadMaintenance(nav.dataset.page);
  const test=event.target.closest('[data-maint-command]');
  if(test){
    const text=test.dataset.maintCommand;
    try{await navigator.clipboard.writeText(text);$('windows-maintenance-message').textContent='Commande copiee : a executer sur .250 dans PowerShell administrateur. Elle cree des profils TEST, sans publier en production.';}
    catch{$('windows-maintenance-message').textContent=text;}
  }
});
$('hp-maintenance-search').addEventListener('input',filterHpMaintenance);
$('hp-maintenance-reload').addEventListener('click',()=>loadMaintenance('hp-maintenance',true));
$('windows-maintenance-reload').addEventListener('click',()=>loadMaintenance('windows-maintenance',true));
$('hp-maintenance-sync').addEventListener('click',async()=>{
  const button=$('hp-maintenance-sync');button.disabled=true;
  try{await api('/hp-repository/refresh','POST',{});await loadMaintenance('hp-maintenance',true);}
  catch(error){$('hp-maintenance-message').textContent=error.message;}finally{button.disabled=false;}
});
$('windows-maintenance-check').addEventListener('click',async()=>{
  const button=$('windows-maintenance-check');button.disabled=true;
  try{await api('/maintenance/windows/check','POST',{});await loadMaintenance('windows-maintenance');}
  catch(error){$('windows-maintenance-message').textContent=error.message;button.disabled=false;}
});
setInterval(()=>{
  if(document.hidden)return;
  for(const page of ['hp-maintenance','windows-maintenance'])if(!$('page-'+page).hidden)loadMaintenance(page);
},15000);
