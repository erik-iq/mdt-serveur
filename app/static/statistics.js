'use strict';
const statisticsRequests=new Map();
const statisticsFetched=new Map();
function statisticsDuration(value){
  if(!Number.isFinite(value))return 'Non mesurée';
  if(value>=3600)return Math.floor(value/3600)+' h '+Math.floor((value%3600)/60)+' min';
  return measuredDuration(value);
}
const statisticsRate=value=>Number.isFinite(value)?value.toLocaleString('fr-CH',{maximumFractionDigits:1})+' %':'Non disponible';
const networkNumber=value=>value.toLocaleString('fr-CH',{maximumFractionDigits:2});
function networkRate(value){return Number.isFinite(value)?networkNumber(value)+' Mbit/s':'Non mesuré';}
function networkLink(value){
  if(!Number.isFinite(value))return 'Non transmise';
  return value>=1000000000?networkNumber(value/1000000000)+' Gbit/s':networkNumber(value/1000000)+' Mbit/s';
}
function renderNetworkStatistics(value){
  if(!value){
    renderFragment('statistics-network-summary','');
    renderFragment('statistics-network','<p class="padding">Les mesures réseau ne sont pas encore transmises par cette version du serveur.</p>');
    $('statistics-network-coverage').textContent='';return;
  }
  renderFragment('statistics-network-summary',`<article><span>Déploiements mesurés</span><strong>${value.measured}</strong><small>Sur ${value.applications} déploiement(s) dans la période</small></article><article><span>Débit moyen reçu par poste</span><strong>${networkRate(value.average_mbps)}</strong><small>${Number.isFinite(value.average_mbps)?networkNumber(value.average_mbps/8)+' Mo/s, pondéré par la durée':'En attente de mesures exploitables'}</small></article><article><span>Meilleure moyenne par poste</span><strong>${networkRate(value.best_average_mbps)}</strong><small>Minimum des moyennes : ${networkRate(value.lowest_average_mbps)}</small></article><article><span>Liaisons sous 1 Gbit/s</span><strong>${value.known_links?value.below_gigabit:'Non transmise'}</strong><small>Sur ${value.known_links} liaison(s) connue(s), par déploiement</small></article>`);
  $('statistics-network-coverage').textContent=value.missing+' déploiement(s) sans relevé, '+value.unavailable+' avec compteurs indisponibles et '+value.failed_applications+' application(s) d’image en échec exclue(s) des moyennes. Affichage des '+value.listed+' dernières sur '+value.applications+'.';
  renderFragment('statistics-network',value.samples.length?`<table><thead><tr><th>POSTE ET DATE</th><th>MODÈLE ET INTERFACE</th><th>LIAISON DÉCLARÉE</th><th>DÉBIT MOYEN REÇU</th><th>VOLUME REÇU</th><th>DURÉE DE MESURE</th></tr></thead><tbody>${value.samples.map(sample=>`<tr><td><strong>${esc(sample.hostname)}</strong><small>${esc(date(sample.created_at))}</small></td><td>${esc(sample.model)}<small>${esc(sample.adapter_name||'Interface non transmise')}</small></td><td>${sample.link_speed_bps&&sample.link_speed_bps<1000000000?contextBadge('queued',networkLink(sample.link_speed_bps)):esc(networkLink(sample.link_speed_bps))}</td><td>${networkRate(sample.average_mbps)}${Number.isFinite(sample.average_mbps)?`<small>${networkNumber(sample.average_mbps/8)} Mo/s</small>`:''}<small>${esc(sample.reason)}</small></td><td>${Number.isFinite(sample.received_bytes)?networkNumber(sample.received_bytes/1000000)+' Mo':'Non mesurés'}</td><td>${statisticsDuration(sample.duration_seconds)}</td></tr>`).join('')}</tbody></table>`:'<div class="empty"><h3>Aucune mesure réseau sur cette période</h3><p>Les prochains déploiements avec WinPE IQ-6.3 transmettront les mesures après l’application de l’image, si les compteurs sont disponibles.</p></div>');
}
function renderStatistics(value){
  const summary=value.summary;
  renderNetworkStatistics(value.network);
  renderFragment('statistics-summary',`<article><span>Déploiements clôturés</span><strong>${summary.finished}</strong><small>Résultats définitifs sur la période</small></article><article><span>Taux de réussite</span><strong>${statisticsRate(summary.success_rate)}</strong><small>${summary.completed} réussite(s), ${summary.failed} échec(s), ${summary.needs_attention} à vérifier</small></article><article><span>Durée moyenne mesurée</span><strong>${statisticsDuration(summary.average_seconds)}</strong><small>Sur ${summary.timed_successful} déploiement(s) réussi(s)</small></article><article><span>Mesures partielles</span><strong>${summary.partial_successful}</strong><small>${summary.unmeasured_successful} réussite(s) sans chronométrage</small></article>`);
  renderFragment('statistics-models',value.models.length?`<table><thead><tr><th>MODÈLE</th><th>CLÔTURÉS</th><th>RÉUSSITE</th><th>RÉUSSIS</th><th>ÉCHECS</th><th>À VÉRIFIER</th><th>DURÉE MOYENNE MESURÉE</th></tr></thead><tbody>${value.models.map(model=>`<tr><td><strong>${esc(model.model)}</strong><small>${esc(model.manufacturer)}</small></td><td>${model.finished}</td><td>${statisticsRate(model.success_rate)}</td><td>${model.completed}</td><td>${model.failed}</td><td>${model.needs_attention}</td><td>${statisticsDuration(model.average_seconds)}<small>${model.timed_successful} réussite(s) mesurée(s) sur ${model.completed}</small></td></tr>`).join('')}</tbody></table>`:'<div class="empty"><h3>Aucun résultat définitif sur cette période</h3><p>Choisissez une autre période ou attendez la réception des bilans de déploiement.</p></div>');
  const longest=Math.max(1,...value.stages.map(stage=>stage.average_seconds));
  renderFragment('statistics-stages',value.stages.length?value.stages.map((stage,index)=>`<article class="statistics-stage"><div class="section-title"><div><h3><span class="statistics-rank">${index+1}</span>${esc(stage.label)}</h3><p>${stage.samples} déploiement(s) mesuré(s) | Maximum : ${statisticsDuration(stage.maximum_seconds)}</p></div><strong>${statisticsDuration(stage.average_seconds)}</strong></div><progress max="${longest}" value="${stage.average_seconds}" aria-label="Durée moyenne de ${esc(stage.label)} : ${statisticsDuration(stage.average_seconds)}"></progress></article>`).join(''):'<div class="empty"><h3>Pas encore de chronométrages exploitables</h3><p>Les étapes apparaîtront après réception des mesures des déploiements réussis. Les anciens rapports sans durée restent exclus des moyennes.</p></div>');
  $('statistics-exclusions').textContent=summary.excluded_unfinished+' déploiement(s) sans résultat final et '+summary.excluded_cancelled+' annulation(s) exclus du taux de réussite sur cette période.';
  $('statistics-status').textContent='Actualisé le '+date(value.generated_at)+'. '+(value.days?'Déploiements lancés sur les '+value.days+' derniers jours.':'Tout l’historique disponible.');
}
async function loadStatistics(fresh=false){
  if(!sessionReady||(!internalMode&&!token))return;
  const period=$('statistics-period').value;
  if(statisticsRequests.has(period))return statisticsRequests.get(period);
  if(!fresh&&Date.now()-(statisticsFetched.get(period)||0)<15000)return;
  $('statistics-content').setAttribute('aria-busy','true');
  $('statistics-status').textContent='Calcul des statistiques en cours...';
  const task=(async()=>{
    try{
      const value=await api('/statistics/deployments?days='+encodeURIComponent(period));
      if($('statistics-period').value===period)renderStatistics(value);
      statisticsFetched.set(period,Date.now());
    }catch(error){if($('statistics-period').value===period)$('statistics-status').textContent='Actualisation impossible : '+error.message+'. Les derniers chiffres affichés ne sont pas actualisés.';}
  })();
  statisticsRequests.set(period,task);
  try{await task;}finally{
    statisticsRequests.delete(period);
    if($('statistics-period').value===period)$('statistics-content').setAttribute('aria-busy','false');
  }
}
document.addEventListener('click',event=>{if(event.target.closest('[data-page="statistics"]'))loadStatistics();});
$('statistics-period').addEventListener('change',()=>{
  renderFragment('statistics-summary','');
  renderFragment('statistics-network-summary','');
  renderFragment('statistics-network','<p class="padding">Chargement des mesures réseau...</p>');
  $('statistics-network-coverage').textContent='';
  renderFragment('statistics-models','<p class="padding">Chargement de la période sélectionnée...</p>');
  renderFragment('statistics-stages','<p>Chargement des mesures...</p>');
  $('statistics-exclusions').textContent='';
  loadStatistics(true);
});
$('statistics-refresh').addEventListener('click',()=>loadStatistics(true));
setInterval(()=>{if(!document.hidden&&!$('page-statistics').hidden)loadStatistics();},15000);
