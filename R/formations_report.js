(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('formations-data').textContent);
  const $ = id => document.getElementById('formations-' + id);
  const seasons = [...new Set(data.observations.map(r => r.season))].sort((a,b)=>a-b);
  const latest = Math.max(...seasons);
  const latestWeeks = [...new Set(data.observations.filter(r=>r.season===latest&&r.league==='NFL').map(r=>r.week))].sort((a,b)=>a-b);
  let selected = latest;
  const escape = s => String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const fmt = n => n == null ? '—' : n.toFixed(2);
  const percent = n => (100*n).toFixed(1)+'%';
  const signed = (n,digits=2) => (n>0?'+':'')+n.toFixed(digits);
  const diff = (a,b,digits=2,suffix='') => a==null||b==null?'—':`<span class="${a>b?'formations-positive':a<b?'formations-negative':''}">${signed(a-b,digits)}${suffix}</span>`;
  const coarse = () => $('detail').value==='units';
  const order = side => side==='DEF'&&coarse()?['DL','LB','DB']:data.positions[side];
  const counts = row => row.side==='DEF'&&coarse()?[row.counts[0]+row.counts[1],row.counts[2],row.counts[3]+row.counts[4]]:row.counts;
  const inWindow = row => !$('matched').checked || latestWeeks.includes(row.week);
  function summarize(season,league,side,team) {
    const rows=data.observations.filter(r=>r.season===season&&r.league===league&&r.side===side&&inWindow(r)&&(!team||r.team===team));
    const teams=new Map();
    for(const r of rows){if(!teams.has(r.team))teams.set(r.team,[]);teams.get(r.team).push(r);}
    const mean=Array(order(side).length).fill(0), frequencies=new Map();
    for(const group of teams.values()) {
      const denominator=group.reduce((s,r)=>s+r.weight,0);
      for(const r of group){const c=counts(r),weight=r.weight/denominator/teams.size,key=c.join(' / ');c.forEach((v,i)=>mean[i]+=v*weight);frequencies.set(key,(frequencies.get(key)||0)+weight);}
    }
    return {mean:teams.size?mean:mean.map(()=>null),frequencies,teams:teams.size,games:Math.round(rows.reduce((s,r)=>s+r.weight,0))};
  }
  function renderSide(side) {
    const id=side.toLowerCase(),n=summarize(selected,'NFL',side),a=summarize(selected,'ADL',side);
    const excluded=data.coverage.filter(r=>r.season===selected&&r.league==='ADL'&&r.side===side&&inWindow(r)&&!r.included).length;
    $(id+'-sample').textContent=`NFL: ${n.games} team-games · ADL: ${a.games} complete lineups · ${excluded} incomplete or missing`;
    $(id+'-means').innerHTML=order(side).map((p,i)=>`<tr><th scope="row">${p}</th><td>${fmt(n.mean[i])}</td><td>${fmt(a.mean[i])}</td><td>${diff(a.mean[i],n.mean[i])}</td></tr>`).join('')+`<tr class="formations-total"><th scope="row">Total</th><td>${fmt(n.mean.some(v=>v==null)?null:n.mean.reduce((s,v)=>s+v,0))}</td><td>${fmt(a.mean.some(v=>v==null)?null:a.mean.reduce((s,v)=>s+v,0))}</td><td></td></tr>`;
    const keys=[...new Set([...n.frequencies.keys(),...a.frequencies.keys()])].sort((x,y)=>Math.max(n.frequencies.get(y)||0,a.frequencies.get(y)||0)-Math.max(n.frequencies.get(x)||0,a.frequencies.get(x)||0));
    const bar=v=>`<span class="formations-bar"><i style="width:${Math.min(100,v*100)}%"></i></span>${percent(v)}`;
    $(id+'-frequency').innerHTML=keys.map(k=>{const nf=n.frequencies.get(k)||0,ad=a.frequencies.get(k)||0;return `<tr><th scope="row">${k}</th><td>${bar(nf)}</td><td>${bar(ad)}</td><td>${diff(100*ad,100*nf,1,' pp')}</td></tr>`;}).join('')+`<tr class="formations-total"><th>Total</th><td>${n.teams?'100.0%':'—'}</td><td>${a.teams?'100.0%':'—'}</td><td></td></tr>`;
  }
  function render() {
    [...$('years').querySelectorAll('button')].forEach(b=>b.setAttribute('aria-selected',Number(b.dataset.season)===selected?'true':'false'));
    const weeks=[...new Set(data.observations.filter(r=>r.season===selected&&inWindow(r)).map(r=>r.week))].sort((a,b)=>a-b);
    $('context').textContent=`League averages · ${selected}${selected===latest?' season-to-date':''} · weeks ${weeks[0]}–${weeks[weeks.length-1]}`;
    $('matched-label').textContent=`Compare the same weeks across seasons (weeks ${latestWeeks[0]}–${latestWeeks[latestWeeks.length-1]})`;
    $('def-order').textContent='Order: '+order('DEF').join(' / ');
    renderSide('OFF');renderSide('DEF');
    const positions=[...order('OFF'),...order('DEF')];
    $('trend-head').innerHTML='<tr><th>Season</th><th>Weeks</th>'+positions.map(p=>`<th>${p}</th>`).join('')+'</tr>';
    $('trends').innerHTML=seasons.map(year=>{
      const nf=[...summarize(year,'NFL','OFF').mean,...summarize(year,'NFL','DEF').mean],ad=[...summarize(year,'ADL','OFF').mean,...summarize(year,'ADL','DEF').mean];
      const w=[...new Set(data.observations.filter(r=>r.season===year&&inWindow(r)).map(r=>r.week))].sort((a,b)=>a-b);
      return `<tr class="${year===selected?'current':''}"><th scope="row">${year}${year===latest?' YTD':''}</th><td>${w[0]}–${w[w.length-1]}</td>${nf.map((v,i)=>`<td>${fmt(v)} / ${fmt(ad[i])}</td>`).join('')}</tr>`;
    }).join('');
    $('trend-note').textContent=$('matched').checked?`All seasons use the same week numbers: ${latestWeeks.join(', ')}. Each cell is NFL / ADL.`:`Historical seasons use weeks 1–17; ${latest} uses available weeks ${latestWeeks[0]}–${latestWeeks[latestWeeks.length-1]}. Each cell is NFL / ADL.`;
    const franchises=[...new Set(data.coverage.filter(r=>r.season===selected&&r.league==='ADL').map(r=>r.team))].sort();
    $('franchise-head').innerHTML='<tr><th>Franchise</th><th>OFF / DEF lineups</th>'+positions.map(p=>`<th>${p}</th>`).join('')+'</tr>';
    $('franchises').innerHTML=franchises.map(team=>{const o=summarize(selected,'ADL','OFF',team),d=summarize(selected,'ADL','DEF',team);return `<tr><th scope="row">${escape(team)}</th><td>${o.games} / ${d.games}</td>${[...o.mean,...d.mean].map(v=>`<td>${fmt(v)}</td>`).join('')}</tr>`;}).join('');
    const coverage=data.coverage.filter(r=>r.season===selected&&inWindow(r));
    const ties=coverage.filter(r=>r.league==='NFL'&&r.boundary_tie).length;
    $('coverage').textContent=`${selected}: ${coverage.filter(r=>r.league==='NFL').length} NFL team-game sides, with ${ties} tied cutoffs. ADL: ${coverage.filter(r=>r.league==='ADL'&&r.included).length} complete team-week sides; ${coverage.filter(r=>r.league==='ADL'&&!r.included).length} incomplete or missing sides excluded. A side means offense or defense, checked separately.`;
  }
  $('years').innerHTML=seasons.map(year=>`<button type="button" role="tab" aria-controls="formations-report" aria-selected="${year===selected}" data-season="${year}">${year}${year===latest?' · YTD':''}</button>`).join('');
  $('years').addEventListener('click',event=>{const b=event.target.closest('button');if(b){selected=Number(b.dataset.season);render();}});
  for(const id of ['matched','detail'])$(id).addEventListener('change',render);
  $('provenance').textContent='Frozen source captured '+data.manifest.captured_at_utc+'.';
  function selectTab(){const formations=location.hash.startsWith('#formations');document.getElementById('formations-report').hidden=!formations;document.getElementById('roster-composition').hidden=formations;document.querySelectorAll('[aria-label="NFL Realism Report tabs"] a').forEach(a=>{if((a.hash==='#formations-report')===formations)a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');});}
  window.addEventListener('hashchange',selectTab);selectTab();render();
})();
