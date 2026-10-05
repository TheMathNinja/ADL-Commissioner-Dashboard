(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('realism-data').textContent);
  const $ = id => document.getElementById('realism-' + id);
  const fmt = n => Number(n).toFixed(2);
  const pct = (adl,nfl) => { if (!(nfl > 0)) return '—'; const rounded = Number(((adl/nfl-1)*100).toFixed(0)); return (rounded >= 0 ? '+' : '') + rounded + '%'; };
  const comparisonColor = (adl,nfl) => { if (!(nfl > 0)) return 'rgb(102,112,133)'; const difference=adl/nfl-1, weight=Math.min(Math.abs(difference)/0.5,1), neutral=[102,112,133], end=difference>=0?[2,122,72]:[180,35,24]; return 'rgb('+neutral.map((v,i)=>Math.round(v+(end[i]-v)*weight)).join(',')+')'; };
  const positions = ['QB','RB','WR','TE','PK','PN','DT','DE','LB','CB','S','OL','LS','UNMAPPED'];
  const teams = [...new Set(data.totals.map(r => r.team))].filter(t => t !== 'NFL').sort();
  for (const team of teams) {
    const option = document.createElement('option'); option.value = team; option.textContent = team; $('team').append(option);
  }
  function total(season, team) {
    const rows = data.totals.filter(r => r.team === team && (season === 'ALL' && team !== 'NFL' ? r.season !== 'ALL' : String(r.season) === season));
    return Object.fromEntries(['act','ina','observed_roster','ol','ls','unmapped','observed_non_ol_ls'].map(k => [k, rows.reduce((v,r) => v+r[k],0)/(rows.length || 1)]));
  }
  function nflCount(season, team, status, position) {
    const rows = data.summary.filter(r => r.team === team && r.status === status && r.adl_position === position &&
      (season === 'ALL' && team !== 'NFL' ? String(r.season) !== 'ALL' : String(r.season) === season));
    return rows.reduce((v,r) => v+r.mean_players,0)/(rows.length || 1);
  }
  function adlCount(season, status, position) {
    const rows = (data.adl_summary || []).filter(r => String(r.season) === season && r.gameday_status === status && r.adl_position === position);
    return rows.reduce((v,r) => v+r.mean_players,0);
  }
  function render() {
    const season = $('season').value, team = $('team').value, t = total(season,team);
    const adlRostered = positions.filter(position => !['OL','LS'].includes(position)).reduce((sum,position) => sum + adlCount(season,'ACT',position) + adlCount(season,'INA',position),0);
    const difference = t.observed_non_ol_ls > 0 ? Number(((adlRostered/t.observed_non_ol_ls-1)*100).toFixed(1)) : null;
    const differenceText = difference === null ? '—' : (difference >= 0 ? '+' : '') + difference.toFixed(1) + '%';
    $('metrics').innerHTML = [['Avg. NFL Non-OL/LS Rostered',fmt(t.observed_non_ol_ls)],['ADL Rostered',fmt(adlRostered)],['Difference',differenceText]].map((r,i) => `<div class="realism-metric ${i===2?'primary':''}">${r[0]}<strong>${r[1]}</strong></div>`).join('');
    $('context').textContent = `League averages · ${season === 'ALL' ? '2022–2025' : season} · weeks 1–17`;
    let totals = [0,0,0,0,0,0];
    let allTotals = [0,0,0,0,0,0];
    $('positions').innerHTML = positions.filter(position => position !== 'UNMAPPED' || ['ACT','INA'].some(status => nflCount(season,team,status,position) !== 0 || adlCount(season,status,position) !== 0)).map(position => {
      const nonADL = ['OL','LS'].includes(position);
      const aa = nonADL ? 0 : adlCount(season,'ACT',position), ai = nonADL ? 0 : adlCount(season,'INA',position);
      const na = nflCount(season,team,'ACT',position), ni = nflCount(season,team,'INA',position);
      const values = [na,ni,na+ni,aa,ai,aa+ai];
      allTotals = allTotals.map((v,i) => v+values[i]);
      if (!nonADL) totals = totals.map((v,i) => v+values[i]);
      return `<tr class="${nonADL ? 'excluded' : ''}"><td>${position}</td>${values.map((v,i) => `<td${i===5 ? ` style="color:${comparisonColor(aa+ai,na+ni)}"` : ''}>${fmt(v)}</td>`).join('')}<td style="color:${comparisonColor(aa+ai,na+ni)}">(${pct(aa+ai,na+ni)})</td></tr>`;
    }).join('');
    $('positions').innerHTML += `<tr class="realism-total realism-all-total"><th scope="row">All Positions Total</th>${allTotals.map(v => `<td>${fmt(v)}</td>`).join('')}<td></td></tr>`;
    $('positions').innerHTML += `<tr class="realism-total"><th scope="row">Non-OL/LS Total</th>${totals.map((v,i) => `<td${i===5 ? ` style="color:${comparisonColor(totals[5],totals[2])}"` : ''}><strong>${fmt(v)}</strong></td>`).join('')}<td style="color:${comparisonColor(totals[5],totals[2])}"><strong>(${pct(totals[5],totals[2])})</strong></td></tr>`;
    const teamRows = [{label:'NFL Average 2022-2025',season:'ALL',team:'NFL'},
      ...teams.map(tm => ({label:tm,season,team:tm}))];
    $('teams').innerHTML = teamRows.map(row => {
      const r = total(row.season,row.team);
      return `<tr><td>${row.label}</td><td>${fmt(r.observed_roster)}</td><td>${fmt(r.ol)}</td><td>${fmt(r.ls)}</td><td>${fmt(r.observed_non_ol_ls)}</td></tr>`;
    }).join('');
  }
  for (const id of ['season','team']) $(id).addEventListener('change',render);
  $('provenance').textContent = `NFL snapshot captured ${data.manifest.captured_at_utc}; nflreadr ${data.manifest.nflreadr_version}. Annual ADL league ID: ${data.manifest.adl_league_id}. Comparison uses weeks 1–17.`;
  render();
})();
