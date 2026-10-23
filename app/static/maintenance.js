'use strict';
const maintenanceDate=value=>value?date(value):'Non transmis';
const maintenanceBytes=value=>Number.isFinite(value)?size(value):'Non transmis';
const maintenanceStates={preparing:'Préparation en cours',ready_for_test:'Candidate à tester',cancelled_cleanup_required:'Annulée - montage à récupérer',failed_cleanup_required:'Échec - montage à récupérer',testing:'Tests en cours',published:'Publiée',Ready:'Au repos',Running:'En cours',Disabled:'En pause',Unknown:'État non transmis',NotConfigured:'Non planifiée',not_checked:'Recherche non lancée'};
const maintenanceLabel=value=>maintenanceStates[value]||labels[value]||value||'Non transmis';
const maintenanceDuration=value=>Number.isFinite(value)?`${Math.floor(value/60)} min ${Math.round(value%60)} s`:'Non mesuré';
let maintenanceLoading=false;

function maintenanceStorage(value){
  if(!value)return '<p>Mesure du stockage en attente.</p>';
  return `<div class="metrics">${value.volumes.map(v=>`<article><span>Volume ${esc(v.root)}</span><strong>${maintenanceBytes(v.free)}</strong><small>libres sur ${maintenanceBytes(v.total)}</small><progress class="maintenance-capacity" max="100" value="${Math.round(100*v.used/v.total)}" aria-label="Occupation du volume ${esc(v.root)}"></progress><small>${maintenanceBytes(v.used)} utilisés</small></article>`).join('')}</div><details class="panel padding"><summary>Répartition du stockage Atelier</summary><p>${esc(value.note)} Mesure : ${maintenanceDate(value.generated_at)}.</p><div class="table-wrap"><table><thead><tr><th>CATÉGORIE</th><th>TAILLE</th><th>FICHIERS</th><th>MESURE</th></tr></thead><tbody>${value.categories.map(c=>`<tr><td>${esc(c.name)}</td><td>${maintenanceBytes(c.bytes)}${c.complete?'':' (partiel)'}</td><td>${esc(c.files)}</td><td>${maintenanceDate(c.measured_at||value.generated_at)}</td></tr>`).join('')}</tbody></table></div></details>`;
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

  $('hp-maintenance-message').textContent=`Agent : ${maintenanceLabel(value.worker.state)}. ${value.worker.message} Dernier contact : ${maintenanceDate(value.worker.last_seen)}.`;
  maintenanceReplace('hp-maintenance-models',value.models.map(m=>{
    const search=[...m.names,m.platform,...m.packages.flatMap(p=>[p.id,p.title||'',p.version||''])].join(' ').toLowerCase();
    return `<article class="panel padding maintenance-card" data-hp-search="${esc(search)}"><div class="section-title"><div><h3>${esc(m.names.join(' / ')||'Modèle non encore transmis')}</h3><p>Plateforme ${esc(m.platform)} | ${esc(m.os)} ${esc(m.os_version)} | ${m.machine_count} poste(s)</p></div>${badge(m.latest_job?.status||(m.snapshot?'completed':'not_ready'))}</div><p>${m.snapshot?`${m.packages.length} SoftPaq dans la dernière archivé (${maintenanceBytes(m.snapshot.size)}), publiée le ${maintenanceDate(m.snapshot.created_at)}.`:'Aucune archivé disponible sur le serveur pour cette plateforme.'}</p>${m.latest_job?`<p>${esc(m.latest_job.message)}</p>`:''}${m.issues.map(i=>`<p class="form-error">${esc(i)}</p>`).join('')}<p>${!m.required.length?'Aucune liste de SoftPaq attendus transmise.':m.missing.length?'SoftPaq demandés encore absents : '+esc(m.missing.join(', ')):'Tous les SoftPaq demandés sont présents dans la liste du cache.'}</p><details data-maint-key="hp-${esc(m.platform+'-'+m.os_version)}"><summary>Pilotes et logiciels stockés (${m.packages.length})</summary><p>Présence et taille de l’archivé contrôlées. Le tableau ne recalcule pas les empreintes de plusieurs Go à chaque ouverture.</p><div class="table-wrap"><table><thead><tr><th>SOFTPAQ</th><th>DESCRIPTION</th><th>VERSION CVA</th><th>TAILLE EXE</th></tr></thead><tbody>${m.packages.map(p=>`<tr><td>${esc(p.id)}<small>${esc(p.filename)}</small></td><td>${esc(p.title||'Description non renseignée')}</td><td>${esc(p.version||'Non renseignée')}</td><td>${maintenanceBytes(p.size)}</td></tr>`).join('')}</tbody></table></div></details></article>`;
  }).join('')||'<div class="panel padding"><h3>Aucun modèle HP connu</h3><p>Un poste avec HPIA sélectionné transmet sa plateforme et ses recommandations pendant la préparation.</p></div>');
  $('hp-maintenance-history').innerHTML=`<div class="panel table-wrap"><table><thead><tr><th>PLATEFORME</th><th>WINDOWS</th><th>ÉTAT</th><th>DÉTAIL</th><th>ACTUALISÉ LE</th></tr></thead><tbody>${value.jobs.map(j=>`<tr><td>${esc(j.platform)}</td><td>${esc(j.os)} ${esc(j.os_version)}</td><td>${badge(j.status)}</td><td>${esc(j.message)}</td><td>${maintenanceDate(j.updated_at)}</td></tr>`).join('')}</tbody></table></div>`;
  filterHpMaintenance();
}

function servicingStage(value){
  const stages={backup:'Sauvegarde de l’original',export_fast:'Export en compression rapide',mount:'Montage de l’édition',catalog_download:'Catalogue et téléchargement des MSU',commit:'Enregistrement et vérification du WIM',verify_hash:'Vérification finale SHA-256',ready_for_test:'Candidate prête pour les tests'};
  return stages[value]||(value?.startsWith('integrate_')?'Intégration '+value.slice(10):value)||'Étape non transmise';
}

function renderWindowsMaintenance(value){

  const worker=value.worker;
  $('windows-maintenance-source').innerHTML=`<h3>Tâche serveur : ${esc(maintenanceLabel(worker.task_state))}</h3><p>Dernière mesure : ${maintenanceDate(worker.generated_at)} | Dernier lancement : ${maintenanceDate(worker.last_run)} | Résultat : ${esc(worker.last_result??'Non transmis')}</p><p>La planification configurée par Atelier est mensuelle, le 15 à 02:00 (heure du serveur). Une tâche en pause reste en pause. Les données sont publiées par l’agent serveur ; une ancienne mesure ne prouve pas une activité actuelle.</p>${value.images.map(i=>`<p><strong>${esc(i.filename)}</strong> - ${maintenanceBytes(i.size)}<br><span class="hash">SHA-256 ${esc(i.sha256)}</span></p>`).join('')||'<p>Aucun WIM utilisé par un profil Famille ou Pro.</p>'}`;
  const check=value.catalog_check;
  // Le bouton principal prépare désormais le cache KB.
  $('windows-maintenance-catalog').innerHTML=`<p>${esc(maintenanceLabel(check.status))} | ${maintenanceDate(check.checked_at)}</p>${check.message?`<p class="form-error">${esc(check.message)}</p>`:''}${check.contexts.map(c=>`<h3>Windows ${esc(c.family)} ${esc(c.release)} ${esc(c.architecture)}${c.dotnet?' - .NET '+esc(c.dotnet):''}</h3><p>Comparé au passage ${esc(c.compared_run)}. Ce contrôle ne certifie pas que la KB est publiée en production.</p>${c.groups.map(g=>`<p><b>${esc(g.kb)}</b> ${g.new?'<span class="badge queued">Nouveau correctif</span>':'<span class="badge">Déjà observé</span>'} ${esc(g.title)}<br>Publication Microsoft : ${esc(g.published)}${g.target_build?' | Build '+esc(g.target_build):''}</p>`).join('')}`).join('')}${!check.contexts.length?'<p>Les versions détectées dans une préparation WIM sont nécessaires pour rechercher les correctifs compatibles. Aucun téléchargement MSU ni DISM n’est lancé par ce bouton.</p>':''}`;
  maintenanceReplace('windows-maintenance-runs',value.reports.map(r=>`<article class="panel padding maintenance-card"><div class="section-title"><div><h3>${esc(r.source_path?.split(/[\\/]/).pop()||r.run_id)}</h3><p>Exécution ${esc(r.run_id)} | ${maintenanceDate(r.started_at)}</p></div><span class="badge ${esc(r.status)}">${esc(maintenanceLabel(r.status))}</span></div><h3>${esc(servicingStage(r.active_stage))}${r.active_index?' - index '+esc(r.active_index):''}</h3><p>Dernière information : ${maintenanceDate(r.updated_at||r.finished_at||r.started_at)}. ${esc(r.progress_text||'')}</p>${r.error?`<p class="form-error">${esc(r.error)}</p>`:''}<p>${r.layout==='home_pro_fast_v1'?'WIM réduit Famille/Pro | compression fast':'Ancienne préparation - image non réduite'} | Validation : ${esc(r.validation?maintenanceLabel(r.validation.status):'Non enregistrée pour test')}</p><div class="actions"><button class="button secondary" data-inventory-file="${esc(r.download_url)}" data-filename="maintenance-${esc(r.run_id)}.json">Télécharger le rapport JSON</button>${r.status==='ready_for_test'&&!r.validation&&r.candidate_file?.present!==false?`<button class="button secondary" data-maint-command="${esc(r.register_test_command)}">Copier la commande de mise en test</button>`:''}</div><details data-maint-key="wim-${esc(r.run_id)}"><summary>Éditions, correctifs et durées détaillées</summary><div class="table-wrap"><table><thead><tr><th>ÉDITION</th><th>INDEX SOURCE &rarr; CANDIDAT</th><th>CORRECTIFS INTÉGRÉS</th></tr></thead><tbody>${r.indexes.map(i=>`<tr><td>${esc(i.name||i.edition)}</td><td>${esc(i.source_index??i.index)} &rarr; ${esc(i.index)}</td><td>${i.updates.map(g=>`${esc(g.kb)} (${esc(g.exit_code)})<small>${esc(g.title)}</small>`).join('')}</td></tr>`).join('')}</tbody></table></div><h3>Durées mesurées par étape</h3>${r.timings.length?`<div class="table-wrap"><table><thead><tr><th>ÉTAPE</th><th>INDEX</th><th>DURÉE</th><th>ÉTAT</th></tr></thead><tbody>${r.timings.map(t=>`<tr><td>${esc(servicingStage(t.stage))}</td><td>${esc(t.index||'-')}</td><td>${maintenanceDuration(t.duration_seconds)}</td><td>${badge(t.status)}</td></tr>`).join('')}</tbody></table></div>`:'<p>Cette ancienne exécution ne mesure pas les étapes.</p>'}<p>Candidate : ${esc(r.candidate_path)}${r.candidate_file?' | '+(r.candidate_file.present?maintenanceBytes(r.candidate_file.size):'Fichier absent'):''}<br>Sauvegarde : ${esc(r.backup_path)}</p><p>La production est conservée tant que les déploiements de test requis ne sont pas terminés avec succès.</p></details></article>`).join('')||'<div class="panel padding"><p>Aucune préparation publiée dans le suivi. Le prochain passage de l’agent transmettra les rapports existants.</p></div>');
}

async function loadMaintenance(page,fresh=false){
  if(maintenanceLoading||(!sessionReady))return;
  maintenanceLoading=true;
  const overview=page==='overview';
  const hp=page==='hp-maintenance';const message=$(overview?'overview-maintenance-storage':hp?'hp-maintenance-message':'windows-maintenance-message');
  try{
    const value=await api('/maintenance/'+(overview?'storage':hp?'hp':'windows')+(fresh?'?fresh=true':''));
    if(overview)maintenanceReplace('overview-maintenance-storage',maintenanceStorage(value));else if(hp)renderHpMaintenance(value);else{renderWindowsMaintenance(value);await loadWindowsKb();await loadWindowsReleases();message.textContent='Suivi actualisé. Les KB et Windows Update restent manuels pendant la préparation des nouveaux postes ; HPIA précède les logiciels et le dossier IQ.';}
  }catch(error){message.textContent=error.message;}
  finally{maintenanceLoading=false;}
}

document.addEventListener('click',async event=>{
  const nav=event.target.closest('[data-page]');
  if(nav&&['overview','hp-maintenance','windows-maintenance'].includes(nav.dataset.page))await loadMaintenance(nav.dataset.page);
  const test=event.target.closest('[data-maint-command]');
  if(test){
    const text=test.dataset.maintCommand;
    try{await navigator.clipboard.writeText(text);$('windows-maintenance-message').textContent='Commande copiée : à exécuter sur .250 dans PowerShell administrateur. Elle crée des profils TEST, sans publier en production.';}
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
  try{await api('/maintenance/windows/kb/refresh','POST',{});await loadWindowsKb();}
  catch(error){$('windows-maintenance-message').textContent=error.message;}finally{button.disabled=false;}
});
setInterval(()=>{
  if(document.hidden)return;
  for(const page of ['overview','hp-maintenance','windows-maintenance'])if(!$('page-'+page).hidden)loadMaintenance(page);
},15000);

async function loadWindowsKb(){
  const value=await api('/maintenance/windows/kb');
  maintenanceReplace('windows-kb-jobs',value.jobs.map(job=>`<article class="panel padding maintenance-card"><div class="section-title"><h3>Windows ${esc(job.context.family)} ${esc(job.context.release)} ${esc(job.context.architecture)} | .NET ${esc(job.context.dotnet)}</h3>${badge(job.status==='ready'?'completed':job.status)}</div><p>${esc(job.message)}</p><p>Actualisé : ${maintenanceDate(job.updated_at)}</p>${job.groups.map(group=>`<h3>${esc(group.kb)} : ${esc(group.title)}</h3><p>${group.target_build?'Build cible : '+esc(group.target_build):''}</p><div class="table-wrap"><table><thead><tr><th>FICHIER STOCKÉ SUR .250</th><th>TAILLE</th><th>SHA-256</th></tr></thead><tbody>${group.files.map(file=>`<tr><td>${esc(file.filename)}</td><td>${maintenanceBytes(file.size)}</td><td class="hash">${esc(file.sha256)}</td></tr>`).join('')}</tbody></table></div>`).join('')}</article>`).join('')||'<div class="panel padding"><p>Aucun cache préparé. Lancez la recherche des versions connues ; le premier poste peut aussi transmettre automatiquement sa version exacte.</p></div>');
}
$('windows-kb-context').addEventListener('submit',async event=>{
  event.preventDefault();const body=Object.fromEntries(new FormData(event.target));body.build=Number(body.build);
  try{await api('/maintenance/windows/kb/prepare','POST',body);await loadWindowsKb();$('windows-maintenance-message').textContent='Préparation des KB demandée sur .250.';}
  catch(error){$('windows-maintenance-message').textContent=error.message;}
});

async function loadWindowsReleases(){
  const value=await api('/maintenance/windows/releases');
  const states={not_checked:'Vérification non lancée',running:'Vérification en cours',completed:'Vérification terminée',failed:'Vérification impossible'};
  const stale=value.status!=='completed';
  const alert=value.newer_releases.length?`<p><span class="badge queued">Nouvelle version disponible : ${esc(value.newer_releases.join(', '))}</span></p>`:'';
  $('windows-release-status').innerHTML=`<p><strong>${esc(states[value.status]||value.status)}</strong> | Dernière tentative : ${maintenanceDate(value.checked_at)}</p><p>${esc(value.message)}</p>${value.success_at?`<p>Dernier contrôle réussi : ${maintenanceDate(value.success_at)}${stale?' (résultats précédents, à actualiser)':''}.</p>`:''}<p>Versions observées dans l’atelier : ${esc(value.known_releases.join(', ')||'aucune version connue')}.</p>${alert}${value.comparison==='unknown'?'<p>Comparaison disponible après réception du contexte Windows d’un poste ou ajout d’une version exacte dans le dépôt KB.</p>':''}${value.status==='completed'&&value.comparison==='current'?'<p>Aucune version publiée plus récente que la dernière version connue de l’atelier.</p>':''}${value.releases.length?`<div class="table-wrap"><table><thead><tr><th>VERSION STABLE</th><th>DISPONIBLE DEPUIS</th><th>BUILD</th><th>FIN DE SUPPORT FAMILLE ET PRO</th></tr></thead><tbody>${value.releases.map(release=>`<tr><td>Windows 11 ${esc(release.release)}</td><td>${esc(release.available_at)}</td><td>${esc(release.build)}</td><td>${esc(release.home_pro_end||'Non renseignée')}</td></tr>`).join('')}</tbody></table></div>`:''}<div class="actions"><a class="button secondary" href="https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information" target="_blank" rel="noopener">Publication officielle Microsoft</a><a class="button secondary" href="https://www.microsoft.com/software-download/windows11" target="_blank" rel="noopener">Obtenir le média officiel</a></div>`;
}
$('windows-release-check').addEventListener('click',async()=>{
  const button=$('windows-release-check');button.disabled=true;
  try{await api('/maintenance/windows/releases/refresh','POST',{});await loadWindowsReleases();}
  catch(error){$('windows-release-status').textContent=error.message;}
  finally{button.disabled=false;}
});
