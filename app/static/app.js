'use strict';
let token = '', state = null, currentForm = '', refreshing = false, internalMode = false, sessionReady = false;
let requestedDeploymentOpened=false;
const $ = id => document.getElementById(id);
const labels = {not_needed:'Aucune mise a jour necessaire',ready:'Pret',not_ready:'Indisponible',offline:'Depot local',online:'HP Internet',unavailable:'Indisponible',manual:'Manuel',skipped:'Non applicable',active_confirmee_operateur:'Active (confirmee par le technicien)',expiree_confirmee_operateur:'Expiree (confirmee par le technicien)',non_verifie:'Non verifie',passed:'Conforme',not_tested:'Non teste',requested:'Demande',unknown:'Non connu',up_to_date:'A jour',installed:'Installe',deferred:'Reporte',partial:'Partiellement termine',interrupted:'Interrompu',queued:'En attente', running:'En cours', staged:'Image appliquee', failed:'Echec', cancelled:'Annule',completed:'Termine',needs_attention:'A verifier',retry_pending:'Nouvelle tentative prevue',reboot_pending:'Redemarrage prevu'};
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date = s => new Intl.DateTimeFormat('fr-CH',{dateStyle:'short',timeStyle:'short'}).format(new Date(s));
const size = n => n > 1024**3 ? `${(n/1024**3).toFixed(2)} Go` : `${(n/1024**2).toFixed(1)} Mo`;
async function api(path, method='GET', body) {
  const response = await fetch('/api'+path, {method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:body === undefined ? undefined : JSON.stringify(body)});
  const data = await response.json();
  if (!response.ok) {
    if (response.status === 401) { token = ''; if (!$('login-dialog').open) $('login-dialog').showModal(); }
    const error = Array.isArray(data.detail) ? data.detail.map(e => e.msg).join(' | ') : data.detail;
    throw new Error(error || 'La requete a echoue');
  }
  return data;
}
function badge(status) { return `<span class="badge ${esc(status)}">${esc(labels[status] || status)}</span>`; }
function render() {
  if($('automatic-mode')) $('automatic-mode').hidden=!state.auto_enroll;
  document.querySelectorAll('[data-open="deployment"]').forEach(button=>button.hidden=!!state.auto_enroll);
  $('metric-machines').textContent = state.machines.length;
  $('metric-profiles').textContent = state.profiles.length;
  $('metric-active').textContent = state.totals.active;
  $('metric-staged').textContent = state.totals.staged;
  $('deployments-empty').hidden = state.deployments.length > 0;
  $('deployments').innerHTML = state.deployments.map(d=>`<tr data-job="${esc(d.id)}"><td><button class="text-button" data-events="${esc(d.id)}">${esc(d.hostname)}</button><small>${esc(d.mac)}</small></td><td>${esc(d.profile_name)}</td><td>${badge(d.status)}${d.windows_status?`<small>Windows : ${badge(d.windows_status)}</small><small>${esc(d.windows_message)}</small>`:''}</td><td><progress max="100" value="${d.progress}" aria-label="Progression ${d.progress} %"></progress>${d.progress} %</td><td>${date(d.created_at)}</td><td><button class="text-button" data-computer="${esc(d.machine_id)}">Fiche ordinateur</button> <button class="text-button" data-inventory="${esc(d.id)}">Dossier inventaire${d.has_inventory?' disponible':''}</button> ${d.has_report?`<button class="text-button" data-report="${esc(d.id)}">Rapport PDF</button>`:''}${['queued','running'].includes(d.status)?`<button class="cancel" data-cancel="${esc(d.id)}">Annuler</button>`:''}</td></tr>`).join('');
  $('machines-empty').hidden = state.machines.length > 0;
  $('machines').innerHTML = state.machines.map(m=>`<tr><td><button class="text-button" data-computer="${esc(m.id)}">${esc(m.hostname)}</button></td><td class="hash">${esc(m.mac)}</td><td>${esc(m.description)||'-'}</td><td>${date(m.created_at)}</td><td>${(state.reports||[]).filter(r=>r.machine_id===m.id).map(r=>`<button class="text-button" data-report="${esc(r.deployment_id)}">${esc(r.hostname)} | PDF ${date(r.created_at)}</button>`).join(' ' ) || 'En attente du rapport Windows'}</td></tr>`).join('');
  $('profiles').innerHTML = state.profiles.length ? state.profiles.map(p=>{const a=state.assets.find(a=>a.id===p.asset_id);return `<article class="panel profile-card"><span class="badge">WINDOWS ${esc(p.windows_version)} | ${esc(p.edition || 'WIM')}</span><h3>${esc(p.name)}</h3><code>${esc(a?.filename)}</code><p>Index ${p.image_index} | ${esc(p.locale)}<br>${esc(p.settings.timezone)} | ${esc(p.settings.theme)}<br>${p.settings.unattended ? 'Compte Administrateur automatique<br>' : ''}${p.settings.software_mode==='winget'?`${p.settings.winget_packages.length} logiciel(s) WinGet apres Windows`:`${p.settings.bundle_ids.length} bundle(s) | ${p.settings.application_ids.length} logiciel(s)`}<br>${a?size(a.size):''}</p></article>`;}).join('') : '<div class="panel padding"><h3>Creez votre premier profil.</h3><p>Enregistrez un fichier install.wim puis selectionnez l index de l edition avec DISM /Get-WimInfo.</p></div>';
  $('assets').innerHTML = state.assets.map(a=>`<tr><td><b>${esc(a.filename)}</b></td><td><span class="badge">${esc(a.kind)}</span></td><td>${size(a.size)}</td><td class="hash" title="${esc(a.sha256)}">${esc(a.sha256.slice(0,20))}...</td></tr>`).join('') || '<tr><td colspan="4">Aucun fichier enregistre.</td></tr>';
  const hp=state.hp_repository;
  if(hp && $('hp-repository-state')) {
    $('hp-repository-state').textContent=hp.worker.available?hp.worker.message:'Depot non disponible pour le moment. Les postes peuvent continuer directement avec HP.';
    $('hp-repository-refresh').disabled=!hp.jobs.length;
    const seen=new Set();
    $('hp-repository-jobs').innerHTML=hp.jobs.filter(job=>{const key=job.platform+'|'+job.os+'|'+job.os_version;if(seen.has(key))return false;seen.add(key);return true;}).map(job=>{
      const saved=hp.snapshots.find(s=>s.platform===job.platform && s.os===job.os && s.os_version===job.os_version);
      return `<article class="hp-repository-entry"><div><b>HP ${esc(job.platform)} | Windows ${job.os==='win11'?'11':'10'} ${esc(job.os_version)}</b> ${badge(job.status)}<p>${esc(job.message)}</p><small>${saved?'Copie conservee : '+esc(size(saved.size))+' | '+esc(date(saved.created_at)):'Premier telechargement en preparation'}</small></div></article>`;
    }).join('') || '<p>Le depot sera alimente automatiquement au premier poste avec HP Image Assistant selectionne.</p>';
  }


}
async function refresh() {
  if ((!token && !internalMode) || refreshing) return;
  refreshing = true;
  try { state = await api('/state'); render(); $('connection').textContent = ' Console connectee'; $('notice').hidden = true; await openRequestedDeployment(); }
  catch(e) { $('connection').textContent = ' Connexion interrompue'; $('notice').textContent = e.message; $('notice').hidden = false; }
  finally { refreshing = false; }
}
function field(label,name,type='text',extra='') { return `<label>${label}<input name="${name}" type="${type}" ${extra} required></label>`; }
function select(label,name,items) { return `<label for="field-${name}">${label}</label><select id="field-${name}" name="${name}" required><option value="">Selectionner...</option>${items.map(i=>`<option value="${esc(i.id)}">${esc(i.name)}</option>`).join('')}</select>`; }
function optionalField(label,name,extra='') { return `<label>${label}<input name="${name}" ${extra}></label>`; }
function choiceList(label,name,items) { return `<fieldset class="choice-list"><legend>${label}</legend>${items.length?items.map(i=>`<label><input type="checkbox" name="${name}" value="${esc(i.id)}"><span>${esc(i.name)}</span></label>`).join(''):'<p class="muted">Aucun element enregistre.</p>'}</fieldset>`; }
function optionalSelect(label,name,items) { return `<label for="field-${name}">${label}</label><select id="field-${name}" name="${name}"><option value="">Aucun</option>${items.map(i=>`<option value="${esc(i.id)}">${esc(i.name)}</option>`).join('')}</select>`; }
function softwarePresetButtons() {
  return '<div class="actions">'+(state.customization_options.software_presets||[]).map(p=>`<button type="button" class="button secondary" data-software-preset="${esc(p.id)}">${esc(p.name)}</button>`).join('')+'</div>';
}
document.addEventListener('click',event=>{
  const button=event.target.closest('[data-software-preset]');if(!button)return;
  const preset=state?.customization_options.software_presets?.find(p=>p.id===button.dataset.softwarePreset);if(!preset)return;
  $('form-fields').querySelectorAll('[name="winget_packages"]').forEach(input=>input.checked=preset.packages.includes(input.value));
});
function openForm(kind) {
  if (!state) return;
  currentForm=kind; $('form-error').textContent=''; $('submit-resource').disabled=false;
  const titles={machine:'Enregistrer une machine',asset:'Enregistrer un fichier',profile:'Creer un profil Windows',deployment:'Autoriser un deploiement'};
  $('form-title').textContent=titles[kind];
  let content='';
  if(kind==='machine') content=field('Nom Windows du poste','hostname','text','maxlength="15" placeholder="PC-ATELIER-01" pattern="[A-Za-z][A-Za-z0-9-]{0,14}"')+field('Adresse MAC PXE','mac','text','placeholder="00:11:22:33:44:55"')+'<label>Description<input name="description" maxlength="240" placeholder="Bureau, modele ou service"></label>';
  if(kind==='asset') content='<p>Copiez d abord le fichier dans data/artifacts. Son SHA-256 sera calcule par le serveur.</p>'+field('Nom exact du fichier','filename','text','placeholder="install.wim"')+select('Type','kind',[{id:'windows',name:'Image Windows (.wim)'},{id:'application',name:'Installateur / archive de logiciel (.exe, .msi, .zip)'},{id:'wallpaper',name:'Fond d ecran (.jpg, .png)'},{id:'winpe',name:'WinPE (.wim) - iPXE optionnel'},{id:'wimboot',name:'wimboot - iPXE'},{id:'bcd',name:'BCD - iPXE'},{id:'sdi',name:'boot.sdi - iPXE'}]);
  if(kind==='profile') content=field('Nom du profil','name','text','maxlength="80" placeholder="Windows 11 Pro | FR"')+select('Image Windows','asset_id',state.assets.filter(a=>a.kind==='windows').map(a=>({id:a.id,name:a.filename})))+optionalField('Version Windows','windows_version','maxlength="24" placeholder="26H2 - version de votre image"')+select('Edition','edition',[{id:'Pro',name:'Windows Pro'},{id:'Famille',name:'Windows Famille'},{id:'Famille unilingue',name:'Windows Famille unilingue'},{id:'Enterprise',name:'Windows Entreprise'},{id:'Education',name:'Windows Education'},{id:'Autre',name:'Autre edition du WIM'}])+field('Index de l edition (DISM /Get-WimInfo)','image_index','number','min="1" max="100" value="1"')+field('Langue de l image Windows','locale','text','value="fr-FR" pattern="[a-z]{2}-[A-Z]{2}"')+'<details open><summary>Installation et personnalisation</summary>'+select('Clavier','keyboard',state.customization_options.keyboards)+select('Fuseau horaire','timezone',state.customization_options.timezones)+field('Region / formats','user_locale','text','value="fr-CH" pattern="[a-z]{2}-[A-Z]{2}"')+select('Theme Windows','theme',state.customization_options.themes)+optionalSelect('Fond d ecran','wallpaper_asset_id',state.assets.filter(a=>a.kind==='wallpaper').map(a=>({id:a.id,name:a.filename})))+softwarePresetButtons()+choiceList('Installation silencieuse apres Windows','winget_packages',state.customization_options.software_packages)+'</details>';
  if(kind==='deployment') content='<p class="warning-text">Ce deploiement supprimera toutes les partitions du disque choisi. Verifiez sa sauvegarde et son identite avant de confirmer sur le poste.</p>'+select('Poste cible','machine_id',state.machines.map(m=>({id:m.id,name:m.hostname+' | '+m.mac})))+select('Profil Windows','profile_id',state.profiles)+field('Numero de disque WinPE','disk_number','number','value="0" min="0" max="32"')+'<label class="check-row"><input name="wizard_enabled" type="checkbox" checked><span>Autoriser le choix du profil et des parametres dans l assistant PXE</span></label>'+(internalMode ? '<p>Le disque sera indique dans WinPE avant le lancement de l installation.</p>' : field('Confirmation : EFFACER suivi du nom exact du poste','confirmation','text','placeholder="EFFACER PC-ATELIER-01" autocomplete="off"'));
  $('form-fields').innerHTML=content;
  if(kind==='profile') $('form-fields').querySelectorAll('[name="winget_packages"]').forEach(input=>input.checked=['vlc','reader','chrome','anydesk'].includes(input.value));
  const defaults={keyboard:'040c:0000040c',timezone:'Romance Standard Time',theme:'unchanged',user_locale:'fr-CH',wallpaper_asset_id:(state.assets.find(a=>a.kind==='wallpaper' && ['fondatelier.png','fonatelier.png'].includes(a.filename.toLowerCase().replace(/[ _-]/g,'')))?.id || ''),install_mode:'install',manufacturer:'all',edition:'Pro'};
  for(const [name,value] of Object.entries(defaults)) {const input=$('resource-form').elements.namedItem(name);if(input) input.value=value;}
  $('submit-resource').textContent=kind==='deployment'?'Autoriser l effacement':'Enregistrer';
  $('form-dialog').showModal();
}
$('login-form').addEventListener('submit',async e=>{
  e.preventDefault(); token=new FormData(e.target).get('token').trim(); $('login-error').textContent='';
  try { state=await api('/state'); e.target.reset(); $('login-dialog').close(); render(); $('connection').textContent=' Console connectee'; await openRequestedDeployment(); }
  catch(error) { token=''; $('login-error').textContent=error.message; }
});
$('login-dialog').addEventListener('cancel',e=>e.preventDefault());
$('resource-form').addEventListener('submit',async e=>{
  e.preventDefault(); const form=new FormData(e.target), data=Object.fromEntries(form);
  for(const key of ['image_index','disk_number']) if(key in data) data[key]=Number(data[key]);
  if(currentForm==='profile') {
    data.settings={};
    for(const name of ['keyboard','timezone','user_locale','theme','wallpaper_asset_id']) {data.settings[name]=data[name];delete data[name];}
    data.settings.wallpaper_asset_id ||= null;
    for(const name of ['application_ids','bundle_ids']) {data.settings[name]=form.getAll(name);delete data[name];}
    {data.settings.software_mode='winget';data.settings.central_inventory=true;data.settings.winget_packages=form.getAll('winget_packages');delete data.winget_packages;}
  }
  if(currentForm==='deployment') data.wizard_enabled=form.has('wizard_enabled');
  const endpoints={machine:'/machines',asset:'/assets',profile:'/profiles',deployment:'/deployments'};
  $('submit-resource').disabled=true; $('form-error').textContent='';
  try { const result=await api(endpoints[currentForm],'POST',data); $('form-dialog').close();
    if(currentForm==='deployment' && !internalMode) { $('job-id').value=result.id; $('job-token').value=result.agent_token; $('boot-code').value=result.boot_code || 'Mode texte - utilisez le jeton'; $('copy-token').textContent='Copier le jeton'; $('token-dialog').showModal(); }
    await refresh();
  } catch(error) { $('form-error').textContent=error.message; }
  finally { $('submit-resource').disabled=false; }
});
async function showEvents(id) {
  try { const entries=await api('/deployments/'+id+'/events'); $('events').innerHTML=`<button class="button secondary" data-inventory="${esc(id)}">Ouvrir le dossier inventaire</button> `+(state.deployments.find(d=>d.id===id)?.has_report?`<button class="button secondary" data-report="${esc(id)}">Telecharger le rapport PDF</button>`:'')+entries.map(e=>`<article class="event"><time>${date(e.created_at)}</time><div>${badge(e.status)}<p>${esc(e.message)}</p></div></article>`).join(''); if(!$('events-dialog').open) $('events-dialog').showModal(); }
  catch(error) { $('notice').textContent=error.message; $('notice').hidden=false; }
}
document.addEventListener('click',async e=>{
  const computer=e.target.closest('[data-computer]');if(computer){e.stopPropagation();await openComputer(computer.dataset.computer);return;}
  const reportView=e.target.closest('[data-report-view]');if(reportView){e.stopPropagation();await viewComputerReport(reportView.dataset.reportView);return;}
  const history=e.target.closest('[data-history-offset]');if(history){await openComputer(currentComputer,Number(history.dataset.historyOffset));return;}
  const journal=e.target.closest('[data-journal]');if(journal){e.stopPropagation();await showEvents(journal.dataset.journal);return;}
  const directory=e.target.closest('[data-inventory]');if(directory){e.stopPropagation();await openInventory(directory.dataset.inventory);return;}
  const file=e.target.closest('[data-inventory-file]');if(file){await downloadInventory(file.dataset.inventoryFile,file.dataset.filename);return;}
  const report=e.target.closest('[data-report]');
  if(report){e.stopPropagation();await downloadReport(report.dataset.report);return;}

  const nav=e.target.closest('[data-page]'); if(nav){document.querySelectorAll('.page').forEach(p=>p.hidden=p.id!=='page-'+nav.dataset.page);document.querySelectorAll('.nav').forEach(n=>n.classList.toggle('active',n===nav));$('breadcrumb').textContent=nav.textContent.trim();}
  const open=e.target.closest('[data-open]'); if(open) openForm(open.dataset.open);
  const close=e.target.closest('[data-close]'); if(close) { if(close.dataset.close==='token-dialog') clearJobToken(); $(close.dataset.close).close(); }
  const cancel=e.target.closest('[data-cancel]'); if(cancel){e.stopPropagation(); if(confirm('Demander l annulation ? Les operations deja effectuees ne sont pas restaurees.')){try{await api('/deployments/'+cancel.dataset.cancel+'/cancel','POST');await refresh();}catch(error){$('notice').textContent=error.message;$('notice').hidden=false;}}return;}
  const job=e.target.closest('[data-job]'); if(job) await showEvents(job.dataset.job);
});
function clearJobToken() { $('job-token').value=''; $('job-token').type='password'; $('job-id').value=''; $('boot-code').value=''; }
$('token-dialog').addEventListener('close',clearJobToken);
$('copy-token').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('job-token').value);$('copy-token').textContent='Jeton copie';}catch{ $('job-token').type='text';$('job-token').select();$('copy-token').textContent='Selectionne - utilisez Ctrl+C'; }});
$('copy-boot-code').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('boot-code').value);}catch{$('boot-code').select();}});
$('refresh').addEventListener('click',()=> sessionReady ? refresh() : initializeSession());
$('logout').addEventListener('click',()=>{token='';state=null;document.querySelectorAll('dialog[open]').forEach(d=>d.close());location.reload();});
setInterval(()=>{if(!document.hidden) refresh();},5000);

initializeSession();

async function initializeSession() {
  try {
    const response = await fetch('/api/session', {cache:'no-store'});
    if (!response.ok) throw new Error('Impossible de lire la configuration de la console');
    const options = await response.json();
    internalMode = options.internal_mode === true;
    sessionReady = true;
    if (internalMode) {
      $('logout').hidden = true;
      await refresh();
    } else $('login-dialog').showModal();
  } catch (error) {
    $('notice').textContent = error.message;
    $('notice').hidden = false;
    $('connection').textContent = ' Connexion interrompue';
  }
}

async function downloadReport(id) {
  try {
    const response=await fetch('/api/deployments/'+encodeURIComponent(id)+'/report.pdf',{headers:{Authorization:'Bearer '+token}});
    if(!response.ok) throw new Error('Rapport indisponible : '+response.status);
    const url=URL.createObjectURL(await response.blob()), link=document.createElement('a');
    link.href=url;link.download='Rapport-'+id+'.pdf';link.click();setTimeout(()=>URL.revokeObjectURL(url),60000);
  } catch(error){$('notice').textContent=error.message;$('notice').hidden=false;}
}
async function openRequestedDeployment() {
  if(requestedDeploymentOpened || !state)return;
  const query=new URLSearchParams(location.search),id=query.get('deployment');
  if(!/^[a-f0-9-]{36}$/i.test(id||''))return;
  requestedDeploymentOpened=true;
  if(query.get('view')==='inventory'){await openInventory(id);return;}
  const job=state.deployments.find(d=>d.id===id);
  if(job)await openComputer(job.machine_id);
  else {document.querySelectorAll('.page').forEach(p=>p.hidden=p.id!=='page-computer');$('breadcrumb').textContent='Fiche ordinateur';}
  await viewComputerReport(id);
}

async function openInventory(id) {
  try {
    const folder=await api('/deployments/'+encodeURIComponent(id)+'/inventory');
    $('inventory-title').textContent='Inventaire - '+folder.hostname;
    $('inventory-directory').value=folder.server_directory;
    $('inventory-files').innerHTML=folder.files.length?folder.files.map(file=>`<p><button class="button secondary" data-inventory-file="${esc(file.url)}" data-filename="${esc(file.filename)}">Telecharger ${esc(file.filename)}</button> ${size(file.size)}</p>`).join(''):'<p>En attente des fichiers XML/CSV. Ils seront transmis depuis Windows ; le cache prive est conserve si le serveur est indisponible.</p>';
    if(!$('inventory-dialog').open) $('inventory-dialog').showModal();
  } catch(error){$('notice').textContent=error.message;$('notice').hidden=false;}
}
async function downloadInventory(url,filename) {
  try {
    const response=await fetch(url,{headers:{Authorization:'Bearer '+token}});
    if(!response.ok) throw new Error('Inventaire indisponible : '+response.status);
    const blobUrl=URL.createObjectURL(await response.blob()),link=document.createElement('a');
    link.href=blobUrl;link.download=filename;link.click();setTimeout(()=>URL.revokeObjectURL(blobUrl),60000);
  } catch(error){$('notice').textContent=error.message;$('notice').hidden=false;}
}
$('copy-inventory-directory').addEventListener('click',async()=>{
  try {await navigator.clipboard.writeText($('inventory-directory').value);}
  catch {$('inventory-directory').select();}
});

let currentComputer=null;
function measuredDuration(seconds) {
  if(!Number.isFinite(Number(seconds))) return 'Non mesure';
  seconds=Math.max(0,Number(seconds));
  if(seconds<1) return seconds.toFixed(2)+' s';
  if(seconds<60) return Math.round(seconds)+' s';
  return Math.floor(seconds/60)+' min '+Math.floor(seconds%60)+' s';
}
function timingRows(measurements) {
  if(!measurements?.length) return '<p>Durees indisponibles pour ce deploiement. Les mesures seront recueillies avec le nouvel agent.</p>';
  const names={running:'Fin de mesure non recue',completed:'Termine',failed:'Echec',deferred:'Reporte',interrupted:'Interrompu'};
  return '<div class="table-wrap"><table><thead><tr><th>Etape</th><th>Duree mesuree</th><th>Etat</th></tr></thead><tbody>'+measurements.map(m=>`<tr><td>${esc(m.label)}<small>${esc(date(m.started_at))}</small></td><td>${m.status==='running' && !m.duration_seconds?'En attente':esc(measuredDuration(m.duration_seconds))}</td><td>${esc(names[m.status]||m.status)}</td></tr>`).join('')+'</tbody></table></div><p class="muted">Mises a jour HP : analyse et installation des SoftPaq en arriere-plan avec IQ-4.3. La preparation de l outil est mesuree separement. Les anciennes installations manuelles ne sont pas chronometrees.</p>';
}
function renderComputerReport(report,id) {
  const tests=report.steps.filter(s=>/^Test /i.test(s.name));
  const warranty=Object.entries(report.inventory).filter(([key])=>/garantie/i.test(key));
  $('computer-report').innerHTML=`<div class="actions"><button class="button secondary" data-report="${esc(id)}">Telecharger le PDF</button><button class="button secondary" data-inventory="${esc(id)}">Dossier inventaire</button></div><p>Rapport du ${esc(date(report.generated_at))} - ${badge(report.status)}</p><h3>Tests materiels</h3>${tests.length?tests.map(t=>`<p><b>${esc(t.name)}</b> : ${esc(labels[t.status]||t.status)} ${esc(t.message)}</p>`).join(''):'<p>Aucun resultat de test materiel transmis.</p>'}<h3>Garantie</h3>${warranty.length?warranty.map(([k,v])=>`<p>${esc(k)} : ${esc(labels[v]||v)}</p>`).join(''):'<p>Garantie non verifiee ou non transmise.</p>'}<h3>Avertissements</h3>${report.warnings.length?'<ul>'+report.warnings.map(w=>`<li>${esc(w)}</li>`).join('')+'</ul>':'<p>Aucun avertissement dans ce rapport.</p>'}<details><summary>Informations techniques</summary><dl class="computer-facts">${Object.entries(report.inventory).map(([k,v])=>`<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl></details><details><summary>Deroulement complet du rapport</summary>${report.steps.map(s=>`<p><b>${esc(s.name)}</b> : ${esc(labels[s.status]||s.status)} - ${esc(s.message)}</p>`).join('')}</details>`;
}
async function viewComputerReport(id) {
  try {renderComputerReport(await api('/deployments/'+encodeURIComponent(id)+'/report'),id);$('computer-report').scrollIntoView({behavior:'smooth',block:'start'});}
  catch(error){$('notice').textContent=error.message;$('notice').hidden=false;}
}
async function openComputer(id,offset=0) {
  try {
    const details=await api('/machines/'+encodeURIComponent(id)+'/details?offset='+offset);
    currentComputer=id;
    document.querySelectorAll('.page').forEach(p=>p.hidden=p.id!=='page-computer');
    document.querySelectorAll('.nav').forEach(n=>n.classList.toggle('active',n.dataset.page==='machines'));
    $('breadcrumb').textContent='Fiche ordinateur';$('computer-title').textContent=details.machine.hostname;
    $('computer-subtitle').textContent=details.machine.mac+' | '+details.total+' deploiement(s)';
    const inventory=details.latest_report?.inventory || {};
    $('computer-summary').innerHTML=`<h2>Identite du poste</h2><dl class="computer-facts">${['Constructeur','Modele','Numero de serie','Windows','RAM (Go)','Processeur','Activation Windows'].map(key=>`<dt>${esc(key)}</dt><dd>${esc(inventory[key]||'Non transmis')}</dd>`).join('')}</dl><p>${esc(details.machine.description)}</p>`;
    $('computer-history').innerHTML=details.deployments.length?details.deployments.map(d=>`<article class="panel padding computer-history-entry"><div class="section-title"><div><h3>${esc(d.profile_name)} - ${esc(d.hostname)}</h3><p>${esc(date(d.created_at))} ${badge(d.windows_status||d.status)}</p></div><div class="actions"><button class="button secondary" data-journal="${esc(d.id)}">Journal</button><button class="button secondary" data-inventory="${esc(d.id)}">Inventaire</button>${d.has_report?`<button class="button secondary" data-report-view="${esc(d.id)}">Voir le rapport</button><button class="button secondary" data-report="${esc(d.id)}">PDF</button>`:''}</div></div><details><summary>Durees par etape</summary>${timingRows(d.timings)}</details></article>`).join(''):'<p>Aucun deploiement pour ce poste.</p>';
    $('computer-pagination').innerHTML=(offset?`<button class="button secondary" data-history-offset="${Math.max(0,offset-details.limit)}">Historique precedent</button>`:'')+(details.has_more?`<button class="button secondary" data-history-offset="${offset+details.limit}">Historique suivant</button>`:'');
    if(details.latest_report) renderComputerReport(details.latest_report,details.latest_report_deployment_id);else $('computer-report').innerHTML='<p>Aucun rapport recu. Les tests, informations Windows et garantie seront affiches apres transmission.</p>';
    $('computer-notes').innerHTML=details.notes.length?details.notes.map(n=>`<article class="computer-note"><small>${esc(date(n.created_at))} ${esc(n.author)}</small><p>${esc(n.text)}</p></article>`).join(''):'<p>Aucune observation enregistree.</p>';
  } catch(error){$('notice').textContent=error.message;$('notice').hidden=false;}
}
$('computer-back').addEventListener('click',()=>document.querySelector('.nav[data-page="machines"]').click());
$('computer-refresh').addEventListener('click',()=>currentComputer && openComputer(currentComputer));
$('computer-note-form').addEventListener('submit',async event=>{
  event.preventDefault();if(!currentComputer)return;
  const button=event.target.querySelector('button');button.disabled=true;$('computer-note-error').textContent='';
  try{await api('/machines/'+encodeURIComponent(currentComputer)+'/notes','POST',Object.fromEntries(new FormData(event.target)));event.target.reset();await openComputer(currentComputer);}
  catch(error){$('computer-note-error').textContent=error.message;}finally{button.disabled=false;}
});

$('hp-repository-refresh').addEventListener('click',async()=>{
  const button=$('hp-repository-refresh');button.disabled=true;
  try {await api('/hp-repository/refresh','POST',{});await refresh();}
  catch(error){$('hp-repository-state').textContent=error.message;}
  finally{button.disabled=false;}
});
