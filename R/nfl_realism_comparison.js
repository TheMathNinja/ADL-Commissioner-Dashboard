(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('realism-data').textContent);
  const $ = id => document.getElementById('realism-' + id);
  const fmt = n => Number(n).toFixed(2);
  const pct = (adl,nfl) => nfl > 0 ? ((adl/nfl-1)*100 >= 0 ? '+' : '') + ((adl/nfl-1)*100).toFixed(1) + '%' : '—';
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
    $('metrics').innerHTML = [['NFL ACT + INA',t.observed_roster,'Observed roster'],['Offensive line',t.ol,'OL · excluded'],['Long snappers',t.ls,'LS · excluded'],['NFL non-OL/LS',t.observed_non_ol_ls,'ACT + INA − OL − LS']].map((r,i) => `<div class="realism-metric ${i===3?'primary':''}">${r[0]}<strong>${fmt(r[1])}</strong><span>${r[2]}</span></div>`).join('');
    $('context').textContent = `${season === 'ALL' ? '2022–2025' : season} · weeks 1–17 · NFL: ${team==='NFL'?'average team':team} · ADL: average franchise. NFL includes OL/LS below; ADL shows zero for these non-ADL positions.`;
    let totals = [0,0,0,0,0,0];
    $('positions').innerHTML = positions.map(position => {
      const nonADL = ['OL','LS'].includes(position);
      const aa = nonADL ? 0 : adlCount(season,'ACT',position), ai = nonADL ? 0 : adlCount(season,'INA',position);
      const na = nflCount(season,team,'ACT',position), ni = nflCount(season,team,'INA',position);
      const values = [na,ni,na+ni,aa,ai,aa+ai];
      if (!nonADL) totals = totals.map((v,i) => v+values[i]);
      return `<tr class="${nonADL ? 'excluded' : ''}"><td>${position}</td>${values.map(v => `<td>${fmt(v)}</td>`).join('')}<td>${pct(aa+ai,na+ni)}</td></tr>`;
    }).join('');
    $('positions').innerHTML += `<tr class="realism-total"><th scope="row">Non-OL/LS Total</th>${totals.map(v => `<td><strong>${fmt(v)}</strong></td>`).join('')}<td><strong>${pct(totals[5],totals[2])}</strong></td></tr>`;
    const teamRows = [{label:'NFL Average 2022-2025',season:'ALL',team:'NFL'},
      ...['2022','2023','2024','2025'].map(year => ({label:year,season:year,team:'NFL'})),
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
