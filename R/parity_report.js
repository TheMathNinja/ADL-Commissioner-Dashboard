(() => {
  'use strict';
  const data=JSON.parse(document.getElementById('parity-data').textContent),$=id=>document.getElementById('parity-'+id);
  const seasons=data.scopes.filter(r=>!r.provisional).map(r=>r.season),latest=Math.max(...data.scopes.map(r=>r.season));let minimum=Math.min(...seasons),maximum=Math.max(...seasons),ytd=false;
  const leagues=['NFL12','ADL','NFL','ADL Reg Season'];
  const avg=xs=>xs.length?xs.reduce((a,b)=>a+b,0)/xs.length:null;
  const weighted=(rows,key,weight)=>rows.every(r=>r[key]!=null)?rows.reduce((v,r)=>v+r[key]*weight(r),0)/rows.reduce((v,r)=>v+weight(r),0):null;
  function pooledSeason(league){
    const rows=data.seasons.filter(r=>r.league===league&&r.season>=minimum&&r.season<=maximum),out={};
    for(const key of Object.keys(rows[0])){
      if(Array.isArray(rows[0][key]))out[key]=rows[0][key].map((_,i)=>weighted(rows.map(r=>({...r,value:r[key][i]})),'value',r=>key==='record_histogram'?32:r.games));
      else if(typeof rows[0][key]==='number')out[key]=weighted(rows,key,r=>['mean_margin','mean_percentile_gap','percentile_close_share','percentile_lopsided_share','random_pair_close_share','random_pair_lopsided_share'].includes(key)?r.games:32);
      else out[key]=rows[0][key];
    }
    out.games=rows.reduce((v,r)=>v+r.games,0);
    for(const key of ['win_pct_sd','normalized_net_margin_sd'])out[key]=rows.every(r=>r[key]!=null)?Math.sqrt(avg(rows.map(r=>r[key]**2))):null;
    const teams=data.teams.filter(r=>r.league===league&&r.season>=minimum&&r.season<=maximum);
    out.record_dispersion_ratio=out.win_pct_sd/Math.sqrt(avg(teams.map(r=>.25/r.games)));
    for(const prefix of ['close','lopsided'])out[prefix+'_pairing_index']=out['random_pair_'+prefix+'_share']?out['percentile_'+prefix+'_share']/out['random_pair_'+prefix+'_share']:null;
    return out;
  }
  function pooledMobility(league,rows,transitions){
    const out=Object.fromEntries(mobility.map(([key])=>[key,null]));
    if(!rows.length)return out;
    const xx=rows.reduce((v,r)=>v+r.prior_centered**2,0),yy=rows.reduce((v,r)=>v+r.next_centered**2,0),xy=rows.reduce((v,r)=>v+r.prior_centered*r.next_centered,0);
    out.beta=xx?xy/xx:null;out.regression_to_mean=out.beta==null?null:1-out.beta;out.correlation=xx&&yy?xy/Math.sqrt(xx*yy):null;
    const marginXX=rows.reduce((v,r)=>v+r.prior_margin_centered**2,0),marginYY=rows.reduce((v,r)=>v+r.next_margin_centered**2,0),marginXY=rows.reduce((v,r)=>v+r.prior_margin_centered*r.next_margin_centered,0);out.margin_correlation=league==='ADL Reg Season'||!marginXX||!marginYY?null:marginXY/Math.sqrt(marginXX*marginYY);
    out.mean_absolute_change=avg(rows.map(r=>Math.abs(r.change)));
    const cohort=(key,f)=>rows.reduce((v,r)=>v+r[key]*f(r),0)/rows.reduce((v,r)=>v+r[key],0);
    out.bottom_next_win_pct=cohort('bottom_weight',r=>r.next_win_pct);out.bottom_improvement=cohort('bottom_weight',r=>r.change);out.bottom_to_winning=cohort('bottom_weight',r=>r.next_win_pct>.5);out.bottom_to_top=cohort('bottom_weight',r=>r.next_top_weight);out.top_to_losing=cohort('top_weight',r=>r.next_win_pct<.5);out.top_to_bottom=cohort('top_weight',r=>r.next_bottom_weight);
    out.transition_matrix=Array.from({length:4},(_,i)=>Array.from({length:4},(_,j)=>avg(transitions.map(t=>t.transition_matrix[i][j]))));return out;
  }
  const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=(n,d=2)=>n==null?'—':n.toFixed(d),pct=n=>n==null?'—':(100*n).toFixed(1)+'%',pp=n=>n==null?'—':(100*n).toFixed(1)+' pp';
  const metricRows=(definitions,b,n,a,r)=>definitions.map(([key,label,format,explain])=>`<tr><th scope="row">${label}</th><td>${format(b[key])}</td><td>${format(a[key])}</td><td>${format(n[key])}</td><td>${format(r[key])}</td><td class="parity-explain">${explain}</td></tr>`).join('');
  const within=[
    ['win_pct_sd','Record spread (SD of win %)',n=>n==null?'—':(100*n).toFixed(1)+' pct pts','Standard deviation of team winning percentages; percentage points are not scoring points. Lower = records cluster more closely around the mean.'],
    ['record_dispersion_ratio','Record spread / coin-flip baseline',n=>num(n)+'×','Lower = less imbalance after allowing for games played.'],
    ['middle_band_share','Teams between .375 and .625',pct,'Higher = more teams near a balanced record.'],
    ['top_bottom_gap','Top–bottom quartile gap',pp,'Lower = less separation between the strongest and weakest records.'],
    ['normalized_net_margin_sd','Net margin spread (SD)',pct,'Lower = average team margins are more closely distributed.'],
    ['mean_percentile_gap','Average opponent scoring-percentile gap',pp,'Lower = opponents performed more similarly relative to other teams that week.'],
    ['percentile_close_share','Close performances · gap ≤10 percentile points',pct,'Higher = more opponents finished near each other in the weekly scoring rankings.'],
    ['percentile_lopsided_share','Lopsided performances · gap ≥50 percentile points',pct,'Lower = fewer opponents finished at least half the scoring rankings apart.'],
    ['close_pairing_index','Close performances / random pairing',n=>n==null?'—':num(n)+'×','1.00× = random pairing of that week’s scores; above 1 means more close pairings. Accounts for ties and different numbers of teams playing.'],
    ['lopsided_pairing_index','Lopsided performances / random pairing',n=>n==null?'—':num(n)+'×','Below 1 means fewer lopsided pairings than random pairing of that week’s scores.'],
  ];
  const mobility=[
    ['correlation','Record persistence · r',num,'Lower positive correlation = less continuity in records.'],
    ['margin_correlation','Normalized net-margin persistence · r',num,'A second persistence measure based on scoring margins.'],
    ['mean_absolute_change','Average absolute win % movement',pp,'Larger = more year-to-year movement; also affected by record noise.'],
    ['bottom_next_win_pct','Bottom quartile · next-year win %',pct,'How far weaker teams rebound on average.'],
    ['bottom_improvement','Bottom quartile · average improvement',pp,'Change in winning percentage for the prior bottom group.'],
    ['bottom_to_winning','Bottom quartile → winning record',pct,'Prior bottom-quarter teams finishing strictly above .500.'],
    ['bottom_to_top','Bottom quartile → top quartile',pct,'A complete leap from the bottom group to the top group.'],
    ['top_to_losing','Top quartile → losing record',pct,'Prior top-quarter teams finishing strictly below .500.'],
    ['top_to_bottom','Top quartile → bottom quartile',pct,'A complete fall from the top group to the bottom group.']
  ];
  const bands=(labels,b,n,a,r)=>labels.map((label,i)=>{const bar=v=>`<span class="parity-bar"><i style="width:${100*v}%"></i></span>${pct(v)}`;return `<tr><th scope="row">${label}</th><td>${bar(b[i])}</td><td>${bar(a[i])}</td><td>${bar(n[i])}</td>${r?`<td>${bar(r[i])}</td>`:''}</tr>`;}).join('');
  function scatterOverlay(groups){
    const x=v=>48+v*282,y=v=>330-v*282;
    let svg='<svg class="parity-scatter" viewBox="0 0 390 390" role="img" aria-label="NFL and ADL prior versus next year winning percentage"><rect x="48" y="48" width="282" height="282" fill="#fafbfc" stroke="#d0d5dd"/>';
    for(const v of [0,.25,.5,.75,1])svg+=`<line x1="48" x2="330" y1="${y(v)}" y2="${y(v)}" stroke="#e4e7ec"/><text x="40" y="${y(v)+4}" text-anchor="end" font-size="11" fill="#667085">${v*100}</text><text x="${x(v)}" y="350" text-anchor="middle" font-size="11" fill="#667085">${v*100}</text>`;
    svg+='<line x1="48" y1="330" x2="330" y2="48" stroke="#98a2b3" stroke-dasharray="4 4"/>';
    for(const {rows,pool,color,label} of groups){
      const mx=avg(rows.map(r=>r.prior_win_pct)),my=avg(rows.map(r=>r.next_win_pct));
      if(pool.beta!=null)svg+=`<line x1="48" x2="330" y1="${y(Math.max(0,Math.min(1,my-pool.beta*mx)))}" y2="${y(Math.max(0,Math.min(1,my+pool.beta*(1-mx))))}" stroke="${color}" stroke-width="2"/>`;
      for(const r of rows)svg+=`<circle data-league="${r.league}" cx="${x(r.prior_win_pct)}" cy="${y(r.next_win_pct)}" r="4" fill="${color}" opacity=".55"><title>${label} · ${esc(r.team)} (${r.from_season}→${r.to_season}): ${pct(r.prior_win_pct)} → ${pct(r.next_win_pct)}</title></circle>`;
    }
    svg+='<text x="190" y="377" text-anchor="middle" font-size="12">Prior season win %</text><text transform="translate(14 190) rotate(-90)" text-anchor="middle" font-size="12">Next season win %</text></svg>';
    return '<p class="parity-legend">'+groups.map(g=>`<span style="color:${g.color}">● ${g.label} · r = ${num(g.pool.correlation)}</span>`).join(' ')+ '</p>'+svg;
  }
  function matrix(values){const labels=['Bottom 25%','Lower middle','Upper middle','Top 25%'];return '<table class="parity-table parity-matrix"><thead><tr><th>Prior → next</th>'+labels.map(l=>`<th>${l}</th>`).join('')+'</tr></thead><tbody>'+values.map((row,i)=>`<tr><th scope="row">${labels[i]}</th>${row.map(v=>`<td style="background:rgba(23,78,166,${v*.65})">${pct(v)}</td>`).join('')}</tr>`).join('')+'</tbody></table>';}
  function render(){
    $('range-controls').hidden=ytd;$('completed').setAttribute('aria-selected',String(!ytd));$('ytd').setAttribute('aria-selected',String(ytd));
    const selected=latest,scope=data.scopes.find(r=>r.season===latest),label=ytd?`${latest} season-to-date`:`${minimum}–${maximum} pooled`;
    const [b,a,n,rs]=leagues.map(league=>ytd?data.seasons.find(r=>r.season===latest&&r.league===league):pooledSeason(league));
    $('context').textContent=`Regular-season comparisons · ${label}`;
    $('partial').hidden=!ytd;$('partial').textContent='2026 is provisional and stays separate from completed-season pools.';
    $('sample').textContent=`${ytd?32:32*(maximum-minimum+1)} team-seasons per league · NFL weeks 1–12: ${b.games} games · ADL H2H: ${a.games} games · NFL weeks 1–17: ${n.games} games. Team-seasons weighted equally; performance gaps pool games.`;
    const mainWithin=['win_pct_sd','middle_band_share','mean_percentile_gap','percentile_close_share','percentile_lopsided_share'];
    $('metrics').innerHTML=metricRows(within.filter(r=>mainWithin.includes(r[0])),b,n,a,rs);
    $('extra-metrics').innerHTML=metricRows(within.filter(r=>!mainWithin.includes(r[0])),b,n,a,rs);
    $('record-bands').innerHTML=bands(['Below 25%','25–<37.5%','37.5–62.5%','>62.5–75%','Above 75%'],b.record_histogram,n.record_histogram,a.record_histogram,rs.record_histogram);
    $('margin-bands').innerHTML=bands(['0–10 percentile points','>10–<25 percentile points','25–<50 percentile points','50+ percentile points'],b.percentile_gap_histogram,n.percentile_gap_histogram,a.percentile_gap_histogram);
    const movement=data.movements.filter(r=>ytd?r.to_season===latest:r.from_season>=minimum&&r.to_season<=maximum&&!r.provisional),transitions=data.transitions.filter(r=>ytd?r.to_season===latest:r.from_season>=minimum&&r.to_season<=maximum&&!r.provisional);
    const pools=leagues.map(league=>pooledMobility(league,movement.filter(r=>r.league===league),transitions.filter(r=>r.league===league)));
    const mainMobility=['correlation','mean_absolute_change','bottom_to_winning','top_to_losing'];
    $('mobility-metrics').innerHTML=metricRows(mobility.filter(r=>mainMobility.includes(r[0])),pools[0],pools[2],pools[1],pools[3]);
    $('extra-mobility').innerHTML=metricRows(mobility.filter(r=>!mainMobility.includes(r[0])),pools[0],pools[2],pools[1],pools[3]);
    $('mobility-title').textContent=`Year-to-year comparison · ${label}`;
    $('mobility-sample').textContent=movement.length?`${movement.length/4} franchise transitions per league. Adjacent seasons inside the selected range.`:'Select at least two years to measure year-to-year mobility.';
    $('transition-views').hidden=!movement.length;
    $('transition-title').textContent=`${label} · franchise movement`;
    $('transition-note').textContent=ytd?'Provisional: 2025 compared with 2026 season-to-date.':'Dots represent franchise-year transitions within the selected range. Regression uses season-centered values.';
    $('recovery-panel').hidden=ytd||minimum===maximum;
    $('recovery-note').textContent=`Follow the ${minimum} bottom and top quartiles through ${maximum}. Cumulative first-crossing rates count whether each franchise crosses .500 at least once; it need not stay there.`;
    $('recovery').innerHTML=Array.from({length:maximum-minimum},(_,i)=>i+1).map(h=>{
      const values=leagues.map(league=>{const baseline=data.movements.filter(r=>r.league===league&&r.from_season===minimum);const rate=(key,winning)=>baseline.reduce((v,r)=>v+r[key]*data.teams.some(t=>t.league===league&&t.team_id===r.team_id&&t.season>minimum&&t.season<=minimum+h&&(winning?t.win_pct>.5:t.win_pct<.5)),0)/baseline.reduce((v,r)=>v+r[key],0);return [rate('bottom_weight',true),rate('top_weight',false)];});
      return `<tr><th>Within ${h} season${h===1?'':'s'}</th>${[0,1].map(k=>values.map(v=>`<td>${pct(v[k])}</td>`).join('')).join('')}</tr>`;
    }).join('');
    for(const league of ['NFL12','ADL','NFL','ADL Reg Season']){
      const id=league==='ADL Reg Season'?'adl-reg':league.toLowerCase(),t=pools[leagues.indexOf(league)];
      if(movement.length)$(id+'-matrix').innerHTML=matrix(t.transition_matrix);
      const source=data.teams.filter(r=>r.league===league&&(ytd?r.season===latest:r.season>=minimum&&r.season<=maximum)),grouped=new Map();
      for(const r of source){if(!grouped.has(r.team_id))grouped.set(r.team_id,{...r,wins:0,losses:0,ties:0,games:0,normalized_net_margin:0,count:0});const v=grouped.get(r.team_id);for(const key of ['wins','losses','ties','games'])v[key]+=r[key];v.normalized_net_margin+=r.normalized_net_margin;v.count++;v.team=r.team;}
      const teams=[...grouped.values()].map(r=>({...r,win_pct:(r.wins+.5*r.ties)/r.games,normalized_net_margin:r.normalized_net_margin/r.count})).sort((x,y)=>y.win_pct-x.win_pct);
      $(id+'-records').innerHTML=teams.map(r=>`<tr><th scope="row">${esc(r.team)}</th><td>${r.wins}–${r.losses}–${r.ties}</td><td>${pct(r.win_pct)}</td><td>${league==='ADL Reg Season'?'—':pct(r.normalized_net_margin)}</td></tr>`).join('');
    }
    if(movement.length){for(const [id,pair] of [['short',[0,1]],['long',[2,3]]])$(id+'-scatter').innerHTML=scatterOverlay(pair.map((index,i)=>({rows:movement.filter(r=>r.league===leagues[index]),pool:pools[index],color:i?'#c83a3f':'#174ea6',label:i?(index===1?'ADL H2H':'ADL Reg Season'):'NFL'})));}
    $('movements').innerHTML=movement.sort((x,y)=>Math.abs(y.change)-Math.abs(x.change)).map(r=>`<tr><td>${r.league==='ADL'?'ADL H2H':r.league==='NFL12'?'NFL weeks 1–12':r.league==='NFL'?'NFL weeks 1–17':r.league}</td><th scope="row">${esc(r.team)}</th><td>${r.from_season}→${r.to_season}</td><td>${pct(r.prior_win_pct)}</td><td>${pct(r.next_win_pct)}</td><td class="${r.change>0?'parity-positive':r.change<0?'parity-negative':''}">${r.change>0?'+':''}${pp(r.change)}</td></tr>`).join('');
  }
  const options=seasons.map(year=>`<option value="${year}">${year}</option>`).join('');$('minimum').innerHTML=options;$('maximum').innerHTML=options;$('minimum').value=minimum;$('maximum').value=maximum;
  $('minimum').addEventListener('change',()=>{minimum=Number($('minimum').value);if(minimum>maximum){maximum=minimum;$('maximum').value=maximum;}render();});
  $('maximum').addEventListener('change',()=>{maximum=Number($('maximum').value);if(maximum<minimum){minimum=maximum;$('minimum').value=minimum;}render();});
  $('completed').addEventListener('click',()=>{ytd=false;render();});$('ytd').addEventListener('click',()=>{ytd=true;render();});
  $('method-scope').textContent=data.matched_weeks?'Both leagues use regular-season weeks 1–12 in completed seasons, and completed weeks only in 2026.':'Completed seasons use ADL regular-season weeks 1–12 and NFL regular-season weeks 1–17, excluding NFL week 18. The 2026 season stops at the latest fully completed NFL week.';
  $('provenance').textContent='Frozen comparison captured '+data.captured_at_utc+'.';
  function selectTab(){const tab=location.hash.startsWith('#parity')?'parity-report':location.hash.startsWith('#formations')?'formations-report':'roster-composition';for(const id of ['roster-composition','formations-report','parity-report']){const e=document.getElementById(id);if(e)e.hidden=id!==tab;}document.querySelectorAll('[aria-label="NFL Realism Report tabs"] a').forEach(a=>{if(a.hash==='#'+tab)a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');});}
  window.addEventListener('hashchange',selectTab);selectTab();render();
})();
