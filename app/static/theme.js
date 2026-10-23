'use strict';
// Appliquer la préférence avant la feuille de style pour éviter un éclair clair au chargement.
(()=>{
  const key='atelier-pxe-theme';
  const modes=new Set(['light','dark','auto']);
  const system=window.matchMedia('(prefers-color-scheme: dark)');
  let preference='auto';
  try{const saved=localStorage.getItem(key);if(modes.has(saved))preference=saved;}catch{}
  function apply(){
    document.documentElement.dataset.theme=preference==='auto'?(system.matches?'dark':'light'):preference;
    const picker=document.getElementById('site-theme');
    if(picker)picker.value=preference;
  }
  function choose(value){
    preference=modes.has(value)?value:'auto';
    try{localStorage.setItem(key,preference);}catch{}
    apply();
  }
  system.addEventListener('change',()=>{if(preference==='auto')apply();});
  window.addEventListener('storage',event=>{
    if(event.key===key||event.key===null){preference=modes.has(event.newValue)?event.newValue:'auto';apply();}
  });
  document.addEventListener('DOMContentLoaded',()=>{
    const picker=document.getElementById('site-theme');
    if(picker)picker.addEventListener('change',event=>choose(event.target.value));
    apply();
  });
  apply();
})();
