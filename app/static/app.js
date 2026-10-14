'use strict';
let token = '', state = null, currentForm = '', refreshing = false;
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
  $('profiles').innerHTML = state.profiles.length ? state.profiles.map(p=>{const a=state.assets.find(a=>a.id===p.asset_id);return `<article class="panel profile-card"><span class="badge">WINDOWS / WIM</span><h3>${esc(p.name)}</h3><code>${esc(a?.filename)}</code><p>Édition n° ${p.image_index} · ${esc(p.locale)}<br>${a?size(a.size):''}</p></article>`;}).join('') : '<div class="panel padding"><h3>Créez votre premier profil.</h3><p>Enregistrez un fichier install.wim puis sélectionnez l’index de l’édition avec DISM /Get-WimInfo.</p></div>';
  $('assets').innerHTML = state.assets.map(a=>`<tr><td><b>${esc(a.filename)}</b></td><td><span class="badge">${esc(a.kind)}</span></td><td>${size(a.size)}</td><td class="hash" title="${esc(a.sha256)}">${esc(a.sha256.slice(0,20))}…</td></tr>`).join('') || '<tr><td colspan="4">Aucun fichier enregistré.</td></tr>';
  $('boot-status').textContent = state.boot_ready ? 'Fichiers iPXE enregistrés. Le démarrage réseau reste à tester sur le LAN.' : 'Transport iPXE non préparé. Utilisez l’image WinPE importée dans WDS.';
  $('boot-url').textContent = state.base_url+'/boot/menu.ipxe';
}
async function refresh() {
  if (!token || refreshing) return;
  refreshing = true;
  try { state = await api('/state'); render(); $('connection').textContent = '● Console connectée'; $('notice').hidden = true; }
  catch(e) { $('connection').textContent = '● Connexion interrompue'; $('notice').textContent = e.message; $('notice').hidden = false; }
  finally { refreshing = false; }
}
function field(label,name,type='text',extra='') { return `<label>${label}<input name="${name}" type="${type}" ${extra} required></label>`; }
function select(label,name,items) { return `<label for="field-${name}">${label}</label><select id="field-${name}" name="${name}" required><option value="">Sélectionner…</option>${items.map(i=>`<option value="${esc(i.id)}">${esc(i.name)}</option>`).join('')}</select>`; }
function openForm(kind) {
  if (!state) return;
  currentForm=kind; $('form-error').textContent=''; $('submit-resource').disabled=false;
  const titles={machine:'Enregistrer une machine',asset:'Enregistrer un fichier',profile:'Créer un profil Windows',deployment:'Autoriser un déploiement'};
  $('form-title').textContent=titles[kind];
  let content='';
  if(kind==='machine') content=field('Nom Windows du poste','hostname','text','maxlength="15" placeholder="PC-ATELIER-01" pattern="[A-Za-z][A-Za-z0-9-]{0,14}"')+field('Adresse MAC PXE','mac','text','placeholder="00:11:22:33:44:55"')+'<label>Description<input name="description" maxlength="240" placeholder="Bureau, modèle ou service"></label>';
  if(kind==='asset') content='<p>Copiez d’abord le fichier dans data/artifacts. Son SHA-256 sera calculé par le serveur.</p>'+field('Nom exact du fichier','filename','text','placeholder="install.wim"')+select('Type','kind',[{id:'windows',name:'Image Windows (.wim)'},{id:'winpe',name:'WinPE (.wim) — iPXE optionnel'},{id:'wimboot',name:'wimboot — iPXE'},{id:'bcd',name:'BCD — iPXE'},{id:'sdi',name:'boot.sdi — iPXE'}]);
  if(kind==='profile') content=field('Nom du profil','name','text','maxlength="80" placeholder="Windows 11 Pro · FR"')+select('Image Windows','asset_id',state.assets.filter(a=>a.kind==='windows').map(a=>({id:a.id,name:a.filename})))+field('Index de l’édition (DISM /Get-WimInfo)','image_index','number','min="1" max="100" value="1"')+field('Langue / région','locale','text','value="fr-FR" pattern="[a-z]{2}-[A-Z]{2}"');
  if(kind==='deployment') content='<p class="warning-text">Ce déploiement supprimera toutes les partitions du disque choisi. Vérifiez sa sauvegarde et son identité avant de confirmer sur le poste.</p>'+select('Poste cible','machine_id',state.machines.map(m=>({id:m.id,name:m.hostname+' · '+m.mac})))+select('Profil Windows','profile_id',state.profiles)+field('Numéro de disque WinPE','disk_number','number','value="0" min="0" max="32"')+field('Confirmation : EFFACER suivi du nom exact du poste','confirmation','text','placeholder="EFFACER PC-ATELIER-01" autocomplete="off"');
  $('form-fields').innerHTML=content;
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
  e.preventDefault(); const data=Object.fromEntries(new FormData(e.target));
  for(const key of ['image_index','disk_number']) if(key in data) data[key]=Number(data[key]);
  const endpoints={machine:'/machines',asset:'/assets',profile:'/profiles',deployment:'/deployments'};
  $('submit-resource').disabled=true; $('form-error').textContent='';
  try { const result=await api(endpoints[currentForm],'POST',data); $('form-dialog').close();
    if(currentForm==='deployment') { $('job-id').value=result.id; $('job-token').value=result.agent_token; $('copy-token').textContent='Copier le jeton'; $('token-dialog').showModal(); }
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
function clearJobToken() { $('job-token').value=''; $('job-token').type='password'; $('job-id').value=''; }
$('token-dialog').addEventListener('close',clearJobToken);
$('copy-token').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('job-token').value);$('copy-token').textContent='Jeton copié';}catch{ $('job-token').type='text';$('job-token').select();$('copy-token').textContent='Sélectionné — utilisez Ctrl+C'; }});
$('refresh').addEventListener('click',refresh);
$('logout').addEventListener('click',()=>{token='';state=null;document.querySelectorAll('dialog[open]').forEach(d=>d.close());location.reload();});
setInterval(()=>{if(!document.hidden) refresh();},5000);
$('login-dialog').showModal();
