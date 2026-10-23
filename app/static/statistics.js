'use strict';
const statisticsRequests=new Map();
const statisticsFetched=new Map();
function statisticsDuration(value){
  if(!Number.isFinite(value))return 'Non mesurée';
  if(value>=3600)return Math.floor(value/3600)+' h '+Math.floor((value%3600)/60)+' min';
  return measuredDuration(value);
}
const statisticsRate=value=>Number.isFinite(value)?value.toLocaleString('fr-CH',{maximumFractionDigits:1})+' %':'Non disponible';
function renderStatistics(value){
  const summary=value.summary;
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
  renderFragment('statistics-models','<p class="padding">Chargement de la période sélectionnée...</p>');
  renderFragment('statistics-stages','<p>Chargement des mesures...</p>');
  $('statistics-exclusions').textContent='';
  loadStatistics(true);
});
$('statistics-refresh').addEventListener('click',()=>loadStatistics(true));
setInterval(()=>{if(!document.hidden&&!$('page-statistics').hidden)loadStatistics();},15000);
