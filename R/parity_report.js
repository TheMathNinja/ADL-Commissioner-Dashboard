(() => {
  'use strict';
  const data=JSON.parse(document.getElementById('parity-data').textContent),$=id=>document.getElementById('parity-'+id);
  const seasons=data.scopes.map(r=>r.season),latest=Math.max(...seasons);let selected=Math.max(...data.scopes.filter(r=>!r.provisional).map(r=>r.season));
  const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=(n,d=2)=>n==null?'—':n.toFixed(d),pct=n=>n==null?'—':(100*n).toFixed(1)+'%',pp=n=>n==null?'—':(100*n).toFixed(1)+' pp';
  const metricRows=(definitions,n,a,r)=>definitions.map(([key,label,format,explain])=>`<tr><th scope="row">${label}</th><td>${format(n[key])}</td><td>${format(a[key])}</td><td>${format(r[key])}</td><td class="parity-explain">${explain}</td></tr>`).join('');
  const within=[
    ['win_pct_sd','Record spread (SD)',pp,'Lower = records cluster more closely around the mean.'],
    ['record_dispersion_ratio','Record spread / coin-flip baseline',n=>num(n)+'×','Lower = less imbalance after allowing for games played.'],
    ['middle_band_share','Teams between .375 and .625',pct,'Higher = more teams near a balanced record.'],
    ['top_bottom_gap','Top–bottom quartile gap',pp,'Lower = less separation between the strongest and weakest records.'],
    ['normalized_net_margin_sd','Net margin spread (SD)',pct,'Lower = average team margins are more closely distributed.'],
    ['mean_relative_margin','Mean score-adjusted game margin',pct,'Lower = games finish closer, relative to typical scoring.'],
    ['close_game_share','Close games · margin ≤25%',pct,'Higher = more games within 25% of typical team scoring.'],
    ['blowout_share','Lopsided games · margin ≥50%',pct,'Lower = fewer gaps of at least half typical team scoring.'],
    ['mean_margin','Mean absolute margin · raw points',n=>num(n,1),'Context only: NFL points and ADL fantasy points use different scales.']
  ];
  const mobility=[
    ['beta','Record persistence · β',num,'Lower = prior records carry over less strongly.'],
    ['regression_to_mean','Regression toward the mean · 1 − β',pct,'Higher = more reduction in the prior above/below-average gap.'],
    ['correlation','Record correlation · r',num,'Lower positive correlation = less continuity in records.'],
    ['margin_beta','Normalized net-margin persistence · β',num,'A second persistence measure based on scoring margins.'],
    ['twelve_week_beta','12-week record persistence · β',num,'Sensitivity check: weeks 1–12 in both leagues, with NFL byes retained.'],
    ['mean_absolute_change','Average absolute win % movement',pp,'Larger = more year-to-year movement; also affected by record noise.'],
    ['bottom_next_win_pct','Bottom quartile · next-year win %',pct,'How far weaker teams rebound on average.'],
    ['bottom_improvement','Bottom quartile · average improvement',pp,'Change in winning percentage for the prior bottom group.'],
    ['bottom_to_winning','Bottom quartile → winning record',pct,'Prior bottom-quarter teams finishing strictly above .500.'],
    ['bottom_to_top','Bottom quartile → top quartile',pct,'A complete leap from the bottom group to the top group.'],
    ['top_to_losing','Top quartile → losing record',pct,'Prior top-quarter teams finishing strictly below .500.'],
    ['top_to_bottom','Top quartile → bottom quartile',pct,'A complete fall from the top group to the bottom group.']
  ];
  const bands=(labels,n,a,r)=>labels.map((label,i)=>{const bar=v=>`<span class="parity-bar"><i style="width:${100*v}%"></i></span>${pct(v)}`;return `<tr><th scope="row">${label}</th><td>${bar(n[i])}</td><td>${bar(a[i])}</td>${r?`<td>${bar(r[i])}</td>`:''}</tr>`;}).join('');
  function scatter(rows,beta,league){
    const x=v=>48+v*282,y=v=>330-v*282,color=league==='NFL'?'#174ea6':'#c83a3f';
    const mx=rows.reduce((s,r)=>s+r.prior_win_pct,0)/rows.length,my=rows.reduce((s,r)=>s+r.next_win_pct,0)/rows.length;
    let svg=`<svg class="parity-scatter" viewBox="0 0 390 390" role="img" aria-label="${league} prior versus next year winning percentage"><rect x="48" y="48" width="282" height="282" fill="#fafbfc" stroke="#d0d5dd"/>`;
    for(const v of [0,.25,.5,.75,1])svg+=`<line x1="48" x2="330" y1="${y(v)}" y2="${y(v)}" stroke="#e4e7ec"/><text x="40" y="${y(v)+4}" text-anchor="end" font-size="11" fill="#667085">${v*100}</text><text x="${x(v)}" y="350" text-anchor="middle" font-size="11" fill="#667085">${v*100}</text>`;
    svg+=`<line x1="48" y1="330" x2="330" y2="48" stroke="#98a2b3" stroke-dasharray="4 4"/>`;
    if(beta!=null)svg+=`<line x1="48" x2="330" y1="${y(Math.max(0,Math.min(1,my-beta*mx)))}" y2="${y(Math.max(0,Math.min(1,my+beta*(1-mx))))}" stroke="${color}" stroke-width="2"/>`;
    for(const r of rows)svg+=`<circle cx="${x(r.prior_win_pct)}" cy="${y(r.next_win_pct)}" r="4" fill="${color}" opacity=".65"><title>${esc(r.team)}: ${pct(r.prior_win_pct)} → ${pct(r.next_win_pct)}</title></circle>`;
    return svg+`<text x="190" y="377" text-anchor="middle" font-size="12">Prior season win %</text><text transform="translate(14 190) rotate(-90)" text-anchor="middle" font-size="12">Next season win %</text><text x="48" y="30" font-size="13" fill="${color}">β = ${num(beta)}</text></svg>`;
  }
  function matrix(values){const labels=['Bottom 25%','Lower middle','Upper middle','Top 25%'];return '<table class="parity-table parity-matrix"><thead><tr><th>Prior → next</th>'+labels.map(l=>`<th>${l}</th>`).join('')+'</tr></thead><tbody>'+values.map((row,i)=>`<tr><th scope="row">${labels[i]}</th>${row.map(v=>`<td style="background:rgba(23,78,166,${v*.65})">${pct(v)}</td>`).join('')}</tr>`).join('')+'</tbody></table>';}
  function render(){
    $('years').querySelectorAll('button').forEach(b=>b.setAttribute('aria-selected',Number(b.dataset.season)===selected?'true':'false'));
    const n=data.seasons.find(r=>r.season===selected&&r.league==='NFL'),a=data.seasons.find(r=>r.season===selected&&r.league==='ADL'),rs=data.seasons.find(r=>r.season===selected&&r.league==='ADL Reg Season'),scope=data.scopes.find(r=>r.season===selected);
    $('context').textContent=`Regular-season head-to-head · ${selected}${scope.provisional?' season-to-date':''} · NFL weeks 1–${scope.nfl_max_week} · ADL weeks 1–${scope.adl_max_week}`;
    $('partial').hidden=!scope.provisional;$('partial').textContent='2026 is provisional. Short records are more volatile, and the 2025→2026 transition is excluded from completed-season mobility.';
    $('sample').textContent=`32 teams per league · NFL: ${n.games} games · ADL: ${a.games} games. ADL Reg Season adds Bonus Games to the H2H record. Margins use H2H games only.`;
    $('metrics').innerHTML=metricRows(within,n,a,rs);
    $('record-bands').innerHTML=bands(['Below 25%','25–<37.5%','37.5–62.5%','>62.5–75%','Above 75%'],n.record_histogram,a.record_histogram,rs.record_histogram);
    $('margin-bands').innerHTML=bands(['0–<10%','10–<25%','25–<50%','50–<100%','100% or more'],n.margin_histogram,a.margin_histogram);
    $('trends').innerHTML=seasons.map(year=>{const nf=data.seasons.find(r=>r.season===year&&r.league==='NFL'),ad=data.seasons.find(r=>r.season===year&&r.league==='ADL'),rs=data.seasons.find(r=>r.season===year&&r.league==='ADL Reg Season');return `<tr class="${year===selected?'current':''}"><th scope="row">${year}${year===latest?' YTD':''}</th><td>${pp(nf.win_pct_sd)} / ${pp(ad.win_pct_sd)} / ${pp(rs.win_pct_sd)}</td><td>${num(nf.record_dispersion_ratio)} / ${num(ad.record_dispersion_ratio)} / ${num(rs.record_dispersion_ratio)}</td><td>${pct(nf.normalized_net_margin_sd)} / ${pct(ad.normalized_net_margin_sd)}</td><td>${pct(nf.close_game_share)} / ${pct(ad.close_game_share)}</td></tr>`;}).join('');
    $('mobility-metrics').innerHTML=metricRows(mobility,data.pooled.find(r=>r.league==='NFL'),data.pooled.find(r=>r.league==='ADL'),data.pooled.find(r=>r.league==='ADL Reg Season'));
    $('recovery').innerHTML=[1,2,3,4].map(h=>{const n=data.recovery.find(r=>r.league==='NFL'&&r.seasons_elapsed===h),a=data.recovery.find(r=>r.league==='ADL'&&r.seasons_elapsed===h),rs=data.recovery.find(r=>r.league==='ADL Reg Season'&&r.seasons_elapsed===h);return `<tr><th scope="row">Within ${h} season${h===1?'':'s'}</th><td>${pct(n.bottom_ever_winning)}</td><td>${pct(a.bottom_ever_winning)}</td><td>${pct(rs.bottom_ever_winning)}</td><td>${pct(n.top_ever_losing)}</td><td>${pct(a.top_ever_losing)}</td><td>${pct(rs.top_ever_losing)}</td></tr>`;}).join('');
    $('yearly-mobility').innerHTML=[...new Set(data.transitions.map(r=>r.to_season))].map(year=>{const nf=data.transitions.find(r=>r.to_season===year&&r.league==='NFL'),ad=data.transitions.find(r=>r.to_season===year&&r.league==='ADL'),rs=data.transitions.find(r=>r.to_season===year&&r.league==='ADL Reg Season');return `<tr class="${year===selected?'current':''}"><th scope="row">${year-1}→${year}${ad.provisional?' YTD*':''}</th><td>${num(nf.beta)}</td><td>${num(ad.beta)}</td><td>${num(rs.beta)}</td><td>${pct(nf.regression_to_mean)} / ${pct(ad.regression_to_mean)} / ${pct(rs.regression_to_mean)}</td><td>${pp(nf.mean_absolute_change)} / ${pp(ad.mean_absolute_change)} / ${pp(rs.mean_absolute_change)}</td><td>${pct(nf.bottom_to_winning)} / ${pct(ad.bottom_to_winning)} / ${pct(rs.bottom_to_winning)}</td></tr>`;}).join('');
    const transitions=data.transitions.filter(r=>r.to_season===selected),movement=data.movements.filter(r=>r.to_season===selected);
    $('transition-views').hidden=!transitions.length;
    $('transition-title').textContent=transitions.length?`${selected-1}→${selected}${scope.provisional?' season-to-date':''} · franchise movement`:'Franchise movement';
    $('transition-note').textContent=transitions.length?(scope.provisional?'Provisional: a completed prior season compared with current season-to-date.':'The selected transition follows the same franchises from one regular season to the next.'):'No prior season is included for 2021. Select 2022 or later to see franchise movement.';
    for(const league of ['NFL','ADL','ADL Reg Season']){
      const id=league==='ADL Reg Season'?'adl-reg':league.toLowerCase(),t=transitions.find(r=>r.league===league);
      if(t){$(id+'-scatter').innerHTML=scatter(movement.filter(r=>r.league===league),t.beta,league);$(id+'-matrix').innerHTML=matrix(t.transition_matrix);}
      const teams=data.teams.filter(r=>r.season===selected&&r.league===league).sort((x,y)=>y.win_pct-x.win_pct||y.normalized_net_margin-x.normalized_net_margin);
      $(id+'-records').innerHTML=teams.map(r=>`<tr><th scope="row">${esc(r.team)}</th><td>${r.wins}–${r.losses}–${r.ties}</td><td>${pct(r.win_pct)}</td><td>${league==='ADL Reg Season'?'—':pct(r.normalized_net_margin)}</td></tr>`).join('');
    }
    $('movements').innerHTML=movement.sort((x,y)=>Math.abs(y.change)-Math.abs(x.change)).map(r=>`<tr><td>${r.league==='ADL'?'ADL H2H':r.league}</td><th scope="row">${esc(r.team)}</th><td>${pct(r.prior_win_pct)}</td><td>${pct(r.next_win_pct)}</td><td class="${r.change>0?'parity-positive':r.change<0?'parity-negative':''}">${r.change>0?'+':''}${pp(r.change)}</td></tr>`).join('');
  }
  $('years').innerHTML=seasons.map(year=>`<button type="button" role="tab" aria-controls="parity-report" aria-selected="${year===selected}" data-season="${year}">${year}${year===latest?' · YTD':''}</button>`).join('');
  $('years').addEventListener('click',event=>{const b=event.target.closest('button');if(b){selected=Number(b.dataset.season);render();}});
  $('method-scope').textContent=data.matched_weeks?'Both leagues use regular-season weeks 1–12 in completed seasons, and completed weeks only in 2026.':'Completed seasons use ADL regular-season weeks 1–12 and NFL regular-season weeks 1–17, excluding NFL week 18. The 2026 season stops at the latest fully completed NFL week.';
  $('provenance').textContent='Frozen comparison captured '+data.captured_at_utc+'.';
  function selectTab(){const tab=location.hash.startsWith('#parity')?'parity-report':location.hash.startsWith('#formations')?'formations-report':'roster-composition';for(const id of ['roster-composition','formations-report','parity-report']){const e=document.getElementById(id);if(e)e.hidden=id!==tab;}document.querySelectorAll('[aria-label="NFL Realism Report tabs"] a').forEach(a=>{if(a.hash==='#'+tab)a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');});}
  window.addEventListener('hashchange',selectTab);selectTab();render();
})();
