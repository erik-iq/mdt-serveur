'use strict';
let token = '', state = null, currentForm = '', refreshing = false, internalMode = false, sessionReady = false;
const $ = id => document.getElementById(id);
const labels = {queued:'En attente', running:'En cours', staged:'Image appliquée', failed:'Échec', cancelled:'Annulé'};
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date = s => new Intl.DateTimeFormat('fr-CH',{dateStyle:'short',timeStyle:'short'}).format(new Date(s));
const size = n => n > 1024**3 ? `${(n/1024**3).toFixed(2)} Go` : `${(n/1024**2).toFixed(1)} Mo`;
async function api(path, method='GET', body) {
  const response = await fetch('/api'+path, {method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:body === undefined ? undefined : JSON.stringify(body)});
  const data = await response.json();
  if (!response.ok) {
    if (response.status === 401) { token = ''; if (!$('login-dialog').open) $('login-dialog').showModal(); }
    const error = Array.isArray(data.detail) ? data.detail.map(e => e.msg).join(' · ') : data.detail;
    throw new Error(error || 'La requête a échoué');
  }
  return data;
}
function badge(status) { return `<span class="badge ${esc(status)}">${esc(labels[status] || status)}</span>`; }
function render() {
  $('metric-machines').textContent = state.machines.length;
  $('metric-profiles').textContent = state.profiles.length;
  $('metric-active').textContent = state.totals.active;
  $('metric-staged').textContent = state.totals.staged;
  $('deployments-empty').hidden = state.deployments.length > 0;
  $('deployments').innerHTML = state.deployments.map(d=>`<tr data-job="${esc(d.id)}"><td><button class="text-button" data-events="${esc(d.id)}">${esc(d.hostname)}</button><small>${esc(d.mac)}</small></td><td>${esc(d.profile_name)}</td><td>${badge(d.status)}</td><td><progress max="100" value="${d.progress}" aria-label="Progression ${d.progress} %"></progress>${d.progress} %</td><td>${date(d.created_at)}</td><td>${['queued','running'].includes(d.status)?`<button class="cancel" data-cancel="${esc(d.id)}">Annuler</button>`:''}</td></tr>`).join('');
  $('machines-empty').hidden = state.machines.length > 0;
  $('machines').innerHTML = state.machines.map(m=>`<tr><td><b>${esc(m.hostname)}</b></td><td class="hash">${esc(m.mac)}</td><td>${esc(m.description)||'—'}</td><td>${date(m.created_at)}</td></tr>`).join('');
  $('profiles').innerHTML = state.profiles.length ? state.profiles.map(p=>{const a=state.assets.find(a=>a.id===p.asset_id);return `<article class="panel profile-card"><span class="badge">WINDOWS ${esc(p.windows_version)} · ${esc(p.edition || 'WIM')}</span><h3>${esc(p.name)}</h3><code>${esc(a?.filename)}</code><p>Index ${p.image_index} · ${esc(p.locale)}<br>${esc(p.settings.timezone)} · ${esc(p.settings.theme)}<br>${p.settings.unattended ? 'Compte Administrateur automatique<br>' : ''}${p.settings.bundle_ids.length} bundle(s) · ${p.settings.application_ids.length} logiciel(s)<br>${a?size(a.size):''}</p></article>`;}).join('') : '<div class="panel padding"><h3>Créez votre premier profil.</h3><p>Enregistrez un fichier install.wim puis sélectionnez l’index de l’édition avec DISM /Get-WimInfo.</p></div>';
  $('applications').innerHTML = state.applications.length ? state.applications.map(a=>`<article class="panel profile-card"><span class="badge">${esc(a.manufacturer==='all'?'TOUS LES POSTES':a.manufacturer.toUpperCase())}</span><h3>${esc(a.name)}</h3><p>${esc(a.version || 'Version à renseigner')} · ${a.install_mode==='portable'?'Outil portable':'Installation silencieuse'}</p><code>${esc(state.assets.find(x=>x.id===a.asset_id)?.filename)}</code></article>`).join('') : '<div class="panel padding"><h3>Préparez votre bundle.</h3><p>Enregistrez les installateurs VLC, lecteur PDF et Chrome, puis les outils HP et Lenovo.</p></div>';
  $('bundles').innerHTML = state.bundles.map(b=>`<article class="panel profile-card"><span class="badge">BUNDLE</span><h3>${esc(b.name)}</h3><p>${esc(b.description)}</p><ul>${b.application_ids.map(id=>`<li>${esc(state.applications.find(a=>a.id===id)?.name || id)}</li>`).join('')}</ul></article>`).join('');
  $('assets').innerHTML = state.assets.map(a=>`<tr><td><b>${esc(a.filename)}</b></td><td><span class="badge">${esc(a.kind)}</span></td><td>${size(a.size)}</td><td class="hash" title="${esc(a.sha256)}">${esc(a.sha256.slice(0,20))}…</td></tr>`).join('') || '<tr><td colspan="4">Aucun fichier enregistré.</td></tr>';
  $('boot-status').textContent = state.boot_ready ? 'Fichiers iPXE enregistrés. Le démarrage réseau reste à tester sur le LAN.' : 'Transport iPXE non préparé. Utilisez l’image WinPE importée dans WDS.';
  $('boot-url').textContent = state.base_url+'/boot/menu.ipxe';
}
async function refresh() {
  if ((!token && !internalMode) || refreshing) return;
  refreshing = true;
  try { state = await api('/state'); render(); $('connection').textContent = '● Console connectée'; $('notice').hidden = true; }
  catch(e) { $('connection').textContent = '● Connexion interrompue'; $('notice').textContent = e.message; $('notice').hidden = false; }
  finally { refreshing = false; }
}
function field(label,name,type='text',extra='') { return `<label>${label}<input name="${name}" type="${type}" ${extra} required></label>`; }
function select(label,name,items) { return `<label for="field-${name}">${label}</label><select id="field-${name}" name="${name}" required><option value="">Sélectionner…</option>${items.map(i=>`<option value="${esc(i.id)}">${esc(i.name)}</option>`).join('')}</select>`; }
function optionalField(label,name,extra='') { return `<label>${label}<input name="${name}" ${extra}></label>`; }
function choiceList(label,name,items) { return `<fieldset class="choice-list"><legend>${label}</legend>${items.length?items.map(i=>`<label><input type="checkbox" name="${name}" value="${esc(i.id)}"><span>${esc(i.name)}</span></label>`).join(''):'<p class="muted">Aucun élément enregistré.</p>'}</fieldset>`; }
function optionalSelect(label,name,items) { return `<label for="field-${name}">${label}</label><select id="field-${name}" name="${name}"><option value="">Aucun</option>${items.map(i=>`<option value="${esc(i.id)}">${esc(i.name)}</option>`).join('')}</select>`; }
function openForm(kind) {
  if (!state) return;
  currentForm=kind; $('form-error').textContent=''; $('submit-resource').disabled=false;
  const titles={machine:'Enregistrer une machine',asset:'Enregistrer un fichier',profile:'Créer un profil Windows',deployment:'Autoriser un déploiement',application:'Ajouter un logiciel',bundle:'Créer un bundle'};
  $('form-title').textContent=titles[kind];
  let content='';
  if(kind==='machine') content=field('Nom Windows du poste','hostname','text','maxlength="15" placeholder="PC-ATELIER-01" pattern="[A-Za-z][A-Za-z0-9-]{0,14}"')+field('Adresse MAC PXE','mac','text','placeholder="00:11:22:33:44:55"')+'<label>Description<input name="description" maxlength="240" placeholder="Bureau, modèle ou service"></label>';
  if(kind==='asset') content='<p>Copiez d’abord le fichier dans data/artifacts. Son SHA-256 sera calculé par le serveur.</p>'+field('Nom exact du fichier','filename','text','placeholder="install.wim"')+select('Type','kind',[{id:'windows',name:'Image Windows (.wim)'},{id:'application',name:'Installateur / archive de logiciel (.exe, .msi, .zip)'},{id:'wallpaper',name:'Fond d’écran (.jpg, .png)'},{id:'winpe',name:'WinPE (.wim) — iPXE optionnel'},{id:'wimboot',name:'wimboot — iPXE'},{id:'bcd',name:'BCD — iPXE'},{id:'sdi',name:'boot.sdi — iPXE'}]);
  if(kind==='profile') content=field('Nom du profil','name','text','maxlength="80" placeholder="Windows 11 Pro · FR"')+select('Image Windows','asset_id',state.assets.filter(a=>a.kind==='windows').map(a=>({id:a.id,name:a.filename})))+optionalField('Version Windows','windows_version','maxlength="24" placeholder="26H2 — version de votre image"')+optionalField('Édition','edition','maxlength="40" placeholder="Pro"')+field('Index de l’édition (DISM /Get-WimInfo)','image_index','number','min="1" max="100" value="1"')+field('Langue de l’image Windows','locale','text','value="fr-FR" pattern="[a-z]{2}-[A-Z]{2}"')+'<details open><summary>Installation et personnalisation</summary>'+select('Clavier','keyboard',state.customization_options.keyboards)+select('Fuseau horaire','timezone',state.customization_options.timezones)+field('Région / formats','user_locale','text','value="fr-FR" pattern="[a-z]{2}-[A-Z]{2}"')+optionalField('Propriétaire enregistré','registered_owner','maxlength="80"')+optionalField('Organisation','organization','maxlength="80"')+select('Thème Windows','theme',state.customization_options.themes)+optionalSelect('Fond d’écran','wallpaper_asset_id',state.assets.filter(a=>a.kind==='wallpaper').map(a=>({id:a.id,name:a.filename})))+choiceList('Bundles inclus','bundle_ids',state.bundles)+choiceList('Logiciels supplémentaires','application_ids',state.applications.map(a=>({id:a.id,name:a.name+' '+a.version})))+'</details>';
  if(kind==='application') content=field('Nom du logiciel','name','text','maxlength="80" placeholder="Google Chrome"')+optionalField('Version du logiciel','version','maxlength="40"')+select('Fichier du logiciel','asset_id',state.assets.filter(a=>a.kind==='application').map(a=>({id:a.id,name:a.filename})))+select('Mode','install_mode',[{id:'install',name:'Installation silencieuse'},{id:'portable',name:'Outil portable — ZIP'}])+optionalField('Programme dans le ZIP','entry_point','maxlength="160" placeholder="HPImageAssistant.exe — uniquement pour un ZIP"')+optionalField('Arguments silencieux','arguments','maxlength="1024" placeholder="/S pour VLC ; vide pour un MSI standard"')+select('Constructeur compatible','manufacturer',[{id:'all',name:'Tous les postes'},{id:'hp',name:'HP uniquement'},{id:'lenovo',name:'Lenovo uniquement'}])+'<p class="muted">Les logiciels seront préparés pendant WinPE puis installés au premier démarrage avec un compte administrateur. Les exécutables doivent avoir une signature éditeur valide.</p>';
  if(kind==='bundle') content=field('Nom du bundle','name','text','maxlength="80" placeholder="Poste standard — VLC / PDF / Chrome"')+optionalField('Description du bundle','description','maxlength="240"')+choiceList('Logiciels du bundle','application_ids',state.applications.map(a=>({id:a.id,name:a.name+' '+a.version+' · '+a.manufacturer})));
  if(kind==='deployment') content='<p class="warning-text">Ce déploiement supprimera toutes les partitions du disque choisi. Vérifiez sa sauvegarde et son identité avant de confirmer sur le poste.</p>'+select('Poste cible','machine_id',state.machines.map(m=>({id:m.id,name:m.hostname+' · '+m.mac})))+select('Profil Windows','profile_id',state.profiles)+field('Numéro de disque WinPE','disk_number','number','value="0" min="0" max="32"')+'<label class="check-row"><input name="wizard_enabled" type="checkbox" checked><span>Autoriser le choix du profil et des paramètres dans l’assistant PXE</span></label>'+(internalMode ? '<p>Le disque sera indiqué dans WinPE avant le lancement de l’installation.</p>' : field('Confirmation : EFFACER suivi du nom exact du poste','confirmation','text','placeholder="EFFACER PC-ATELIER-01" autocomplete="off"'));
  $('form-fields').innerHTML=content;
  const defaults={keyboard:'040c:0000040c',timezone:'Romance Standard Time',theme:'unchanged',install_mode:'install',manufacturer:'all'};
  for(const [name,value] of Object.entries(defaults)) {const input=$('resource-form').elements.namedItem(name);if(input) input.value=value;}
  $('submit-resource').textContent=kind==='deployment'?'Autoriser l’effacement':'Enregistrer';
  $('form-dialog').showModal();
}
$('login-form').addEventListener('submit',async e=>{
  e.preventDefault(); token=new FormData(e.target).get('token').trim(); $('login-error').textContent='';
  try { state=await api('/state'); e.target.reset(); $('login-dialog').close(); render(); $('connection').textContent='● Console connectée'; }
  catch(error) { token=''; $('login-error').textContent=error.message; }
});
$('login-dialog').addEventListener('cancel',e=>e.preventDefault());
$('resource-form').addEventListener('submit',async e=>{
  e.preventDefault(); const form=new FormData(e.target), data=Object.fromEntries(form);
  for(const key of ['image_index','disk_number']) if(key in data) data[key]=Number(data[key]);
  if(currentForm==='profile') {
    data.settings={};
    for(const name of ['keyboard','timezone','user_locale','registered_owner','organization','theme','wallpaper_asset_id']) {data.settings[name]=data[name];delete data[name];}
    data.settings.wallpaper_asset_id ||= null;
    for(const name of ['application_ids','bundle_ids']) {data.settings[name]=form.getAll(name);delete data[name];}
  }
  if(currentForm==='bundle') data.application_ids=form.getAll('application_ids');
  if(currentForm==='deployment') data.wizard_enabled=form.has('wizard_enabled');
  const endpoints={machine:'/machines',asset:'/assets',profile:'/profiles',deployment:'/deployments',application:'/applications',bundle:'/bundles'};
  $('submit-resource').disabled=true; $('form-error').textContent='';
  try { const result=await api(endpoints[currentForm],'POST',data); $('form-dialog').close();
    if(currentForm==='deployment' && !internalMode) { $('job-id').value=result.id; $('job-token').value=result.agent_token; $('boot-code').value=result.boot_code || 'Mode texte — utilisez le jeton'; $('copy-token').textContent='Copier le jeton'; $('token-dialog').showModal(); }
    await refresh();
  } catch(error) { $('form-error').textContent=error.message; }
  finally { $('submit-resource').disabled=false; }
});
async function showEvents(id) {
  try { const entries=await api('/deployments/'+id+'/events'); $('events').innerHTML=entries.map(e=>`<article class="event"><time>${date(e.created_at)}</time><div>${badge(e.status)}<p>${esc(e.message)}</p></div></article>`).join(''); if(!$('events-dialog').open) $('events-dialog').showModal(); }
  catch(error) { $('notice').textContent=error.message; $('notice').hidden=false; }
}
document.addEventListener('click',async e=>{
  const nav=e.target.closest('[data-page]'); if(nav){document.querySelectorAll('.page').forEach(p=>p.hidden=p.id!=='page-'+nav.dataset.page);document.querySelectorAll('.nav').forEach(n=>n.classList.toggle('active',n===nav));$('breadcrumb').textContent=nav.textContent.trim();}
  const open=e.target.closest('[data-open]'); if(open) openForm(open.dataset.open);
  const close=e.target.closest('[data-close]'); if(close) { if(close.dataset.close==='token-dialog') clearJobToken(); $(close.dataset.close).close(); }
  const cancel=e.target.closest('[data-cancel]'); if(cancel){e.stopPropagation(); if(confirm('Demander l’annulation ? Les opérations déjà effectuées ne sont pas restaurées.')){try{await api('/deployments/'+cancel.dataset.cancel+'/cancel','POST');await refresh();}catch(error){$('notice').textContent=error.message;$('notice').hidden=false;}}return;}
  const job=e.target.closest('[data-job]'); if(job) await showEvents(job.dataset.job);
});
function clearJobToken() { $('job-token').value=''; $('job-token').type='password'; $('job-id').value=''; $('boot-code').value=''; }
$('token-dialog').addEventListener('close',clearJobToken);
$('copy-token').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('job-token').value);$('copy-token').textContent='Jeton copié';}catch{ $('job-token').type='text';$('job-token').select();$('copy-token').textContent='Sélectionné — utilisez Ctrl+C'; }});
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
    $('connection').textContent = '● Connexion interrompue';
  }
}
