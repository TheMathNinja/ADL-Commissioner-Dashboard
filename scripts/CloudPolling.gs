// Free cloud scheduler for every recurring ADL and FAFL GitHub workflow.
// Install one Apps Script time trigger with installCloudScheduler().
const CLOUD_SCHEDULER = {
  season: 2026,
  easternTimezone: 'America/New_York',
  tokenProperty: 'GITHUB_WORKFLOW_TOKEN',
  alertEmail: 'fili.mikey@gmail.com',
  owner: 'TheMathNinja',
  intervalMinutes: 5,
  maxCatchUpMinutes: 26 * 60,
  circuitFailureThreshold: 3,
  circuitProbeMinutes: 60,
  polling: {
    preliminary: [
      {repo: 'ADL-GM-Dashboard', leagueId: '60206', workflow: 'poll_preliminary_scores.yml', inputs: {dry_run: 'false'}},
      {repo: 'FAFL-GM-Dashboard', leagueId: '22686', workflow: 'poll_preliminary_scores.yml', inputs: {dry_run: 'false'}}
    ],
    corrections: [
      {repo: 'ADL-GM-Dashboard', leagueId: '60206', workflow: 'poll_score_corrections.yml', inputs: {dry_run: 'false'}},
      {repo: 'FAFL-GM-Dashboard', leagueId: '22686', workflow: 'poll_score_corrections.yml', inputs: {dry_run: 'false'}}
    ]
  },
  intervalJobs: [],
  cronJobs: [
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'fafl-inactivity-watch.yml', cron: '7 * * * *', inputs: {dry_run: 'false', probe: 'false'}}
  ],
  // Fixed local times stay stable across daylight-saving changes.
  localJobs: [
    {repo: 'ADL-GM-Dashboard', workflow: 'daily_adl_league_maintenance.yml', timezone: 'America/New_York', hour: 5, minute: 17, inputs: {send_email: 'true'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'dashboard_watchdog.yml', timezone: 'America/New_York', hour: 6, minute: 57, inputs: {}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'lineup-designation-snapshots.yml', timezone: 'America/New_York', hour: 2, minute: 5, months: [1,9,10,11,12], inputs: {}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'lineup-designation-snapshots.yml', timezone: 'America/New_York', hour: 8, minute: 5, months: [1,9,10,11,12], inputs: {}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'lineup-designation-snapshots.yml', timezone: 'America/New_York', hour: 14, minute: 5, months: [1,9,10,11,12], inputs: {}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'lineup-designation-snapshots.yml', timezone: 'America/New_York', hour: 20, minute: 5, months: [1,9,10,11,12], inputs: {}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'offseason-inactivity-monitor.yml', timezone: 'America/New_York', hour: 6, minute: 15, months: [2,3,4,5,6,7,8], inputs: {send_email: 'true', mark_issued: 'false', send_empty: 'false'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'daily-commissioner-alerts.yml', timezone: 'America/New_York', hour: 12, minute: 7, month: 8, day: 31, inputs: {cutdown_id: 'roster_cutdown_1', send_email: 'true'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'daily-commissioner-alerts.yml', timezone: 'America/New_York', hour: 12, minute: 22, month: 8, day: 31, inputs: {cutdown_id: 'roster_cutdown_1', send_email: 'true'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'daily-commissioner-alerts.yml', timezone: 'America/New_York', hour: 12, minute: 7, month: 9, day: 7, inputs: {cutdown_id: 'final_roster_cutdown', send_email: 'true'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'daily-commissioner-alerts.yml', timezone: 'America/New_York', hour: 12, minute: 22, month: 9, day: 7, inputs: {cutdown_id: 'final_roster_cutdown', send_email: 'true'}}
  ]
};

function cloudPollWindowParts_(day, clock, year, month) {
  const inSeason = year === CLOUD_SCHEDULER.season && month >= 9 ||
    year === CLOUD_SCHEDULER.season + 1 && month === 1;
  if (!inSeason) return '';
  if (day === 1 && clock >= '23:15' || day === 2) return 'preliminary';
  if (day === 4 && clock >= '04:15') return 'corrections';
  return '';
}

function cloudPollWindow_(now) {
  const tz = CLOUD_SCHEDULER.easternTimezone;
  return cloudPollWindowParts_(
    Number(Utilities.formatDate(now, tz, 'u')),
    Utilities.formatDate(now, tz, 'HH:mm'),
    Number(Utilities.formatDate(now, tz, 'yyyy')),
    Number(Utilities.formatDate(now, tz, 'M'))
  );
}

function cronFieldMatches_(field, value) {
  return field.split(',').some(function(part) {
    const step = part.split('/');
    if (step.length === 2) {
      const divisor = Number(step[1]);
      if (!divisor) return false;
      if (step[0] === '*') return value % divisor === 0;
    }
    if (part === '*') return true;
    if (part.indexOf('-') >= 0) {
      const bounds = part.split('-').map(Number);
      return value >= bounds[0] && value <= bounds[1];
    }
    return value === Number(part);
  });
}

function cronMatchesUtcParts_(cron, minute, hour, dayOfMonth, month, dayOfWeek) {
  const fields = cron.trim().split(/\s+/);
  if (fields.length !== 5) throw new Error('Unsupported cron expression: ' + cron);
  return cronFieldMatches_(fields[0], minute) && cronFieldMatches_(fields[1], hour) &&
    cronFieldMatches_(fields[2], dayOfMonth) && cronFieldMatches_(fields[3], month) &&
    cronFieldMatches_(fields[4], dayOfWeek);
}

function cronMatchesDate_(cron, date) {
  return cronMatchesUtcParts_(cron, date.getUTCMinutes(), date.getUTCHours(),
    date.getUTCDate(), date.getUTCMonth() + 1, date.getUTCDay());
}

function localJobMatchesParts_(job, year, month, day, hour, minute) {
  return hour === job.hour && minute === job.minute &&
    (!job.months || job.months.indexOf(month) >= 0) &&
    (!job.month || job.month === month) && (!job.day || job.day === day);
}

function localJobMatchesDate_(job, date) {
  const cache = localJobMatchesDate_.cache || (localJobMatchesDate_.cache = Object.create(null));
  const key = job.timezone + '/' + date.getTime();
  const parts = cache[key] || (cache[key] = Utilities.formatDate(date, job.timezone, 'yyyy,M,d,H,m').split(',').map(Number));
  return localJobMatchesParts_(job, parts[0], parts[1], parts[2], parts[3], parts[4]);
}

function cloudTargetWeekParts_(season, year, month, day) {
  if (year !== season && !(year === season + 1 && month === 1)) return 0;
  const septFirst = Date.UTC(season, 8, 1);
  const firstMonday = septFirst + (((8 - new Date(septFirst).getUTCDay()) % 7) + 7) * 86400000;
  const current = Date.UTC(year, month - 1, day);
  const week = Math.floor((current - firstMonday) / (7 * 86400000)) + 1;
  return week >= 1 && week <= 17 ? week : 0;
}

function cloudTargetWeek_(now) {
  const tz = CLOUD_SCHEDULER.easternTimezone;
  return cloudTargetWeekParts_(CLOUD_SCHEDULER.season,
    Number(Utilities.formatDate(now, tz, 'yyyy')),
    Number(Utilities.formatDate(now, tz, 'M')),
    Number(Utilities.formatDate(now, tz, 'd')));
}

function cloudLocalInputsParts_(job, year, month, day) {
  if (job.workflow === 'daily_adl_league_maintenance.yml' && year >= 2027 && month === 7 && day === 1) {
    return {send_email: 'true', enable_mfl_salary_writes: 'true'};
  }
  return job.inputs || {};
}

function cloudLocalInputs_(job, date) {
  return cloudLocalInputsParts_(job,
    Number(Utilities.formatDate(date, job.timezone, 'yyyy')),
    Number(Utilities.formatDate(date, job.timezone, 'M')),
    Number(Utilities.formatDate(date, job.timezone, 'd')));
}

function latestDueMinute_(job, now, lastRun, matcher) {
  const end = Math.floor(now.getTime() / 60000) * 60000;
  const fallbackStart = end - CLOUD_SCHEDULER.maxCatchUpMinutes * 60000;
  // Search the complete recovery window. Per-job receipts make this idempotent,
  // while a shared or corrupt cursor can no longer hide a missed fixed slot.
  for (let stamp = end; stamp >= fallbackStart; stamp -= 60000) {
    const candidate = new Date(stamp);
    if (matcher(job, candidate)) return candidate;
  }
  return null;
}

function cloudHeaders_(token) {
  return {Accept: 'application/vnd.github+json', Authorization: 'Bearer ' + token,
    'X-GitHub-Api-Version': '2022-11-28'};
}

function cloudDispatch_(job, token, overrideInputs) {
  const inputs = Object.assign({}, job.inputs || {}, overrideInputs || {});
  const url = 'https://api.github.com/repos/' + CLOUD_SCHEDULER.owner + '/' + job.repo +
    '/actions/workflows/' + job.workflow + '/dispatches';
  let response;
  for (let attempt = 0; attempt < 4; attempt++) {
    response = UrlFetchApp.fetch(url,
      {method: 'post', headers: cloudHeaders_(token), contentType: 'application/json',
        payload: JSON.stringify({ref: 'main', inputs: inputs}), muteHttpExceptions: true});
    const code = response.getResponseCode();
    if (code === 200 || code === 204) return;
    if ([429, 500, 502, 503, 504].indexOf(code) < 0 || attempt === 3) break;
    Utilities.sleep(Math.pow(2, attempt) * 1000);
  }
  throw new Error(job.repo + '/' + job.workflow + ' returned HTTP ' +
    response.getResponseCode() + ': ' + response.getContentText().slice(0, 500));
}

function cloudVerifyWorkflow_(job, token) {
  const response = UrlFetchApp.fetch(
    'https://api.github.com/repos/' + CLOUD_SCHEDULER.owner + '/' + job.repo +
      '/actions/workflows/' + job.workflow,
    {method: 'get', headers: cloudHeaders_(token), muteHttpExceptions: true}
  );
  if (response.getResponseCode() !== 200) {
    throw new Error(job.repo + '/' + job.workflow + ' is not accessible: HTTP ' + response.getResponseCode());
  }
}

function cloudRepoJson_(repo, path, token) {
  const response = UrlFetchApp.fetch(
    'https://api.github.com/repos/' + CLOUD_SCHEDULER.owner + '/' + repo + '/contents/' + path + '?ref=main',
    {method: 'get', headers: cloudHeaders_(token), muteHttpExceptions: true}
  );
  if (response.getResponseCode() === 404) return null;
  if (response.getResponseCode() !== 200) {
    throw new Error(repo + '/' + path + ' returned HTTP ' + response.getResponseCode());
  }
  const item = JSON.parse(response.getContentText());
  return JSON.parse(Utilities.newBlob(Utilities.base64Decode(String(item.content).replace(/\s/g, ''))).getDataAsString());
}

function cloudWorkflowRuns_(job, token, limit) {
  const response = UrlFetchApp.fetch(
    'https://api.github.com/repos/' + CLOUD_SCHEDULER.owner + '/' + job.repo +
      '/actions/workflows/' + job.workflow + '/runs?event=workflow_dispatch&branch=main&per_page=' + limit,
    {method: 'get', headers: cloudHeaders_(token), muteHttpExceptions: true}
  );
  if (response.getResponseCode() !== 200) {
    throw new Error(job.repo + '/' + job.workflow + ' run history returned HTTP ' +
      response.getResponseCode());
  }
  return (JSON.parse(response.getContentText()).workflow_runs || []);
}

function cloudWorkflowInFlightFromRuns_(runs) {
  return runs.some(function(run) {
    return run.status === 'queued' || run.status === 'in_progress' || run.status === 'waiting' ||
      run.status === 'pending' || run.status === 'requested';
  });
}

function cloudWorkflowInFlight_(job, token) {
  return cloudWorkflowInFlightFromRuns_(cloudWorkflowRuns_(job, token, 10));
}

function cloudPollingCircuitOpen_(job, token, props, now) {
  const runs = cloudWorkflowRuns_(job, token, CLOUD_SCHEDULER.circuitFailureThreshold);
  if (runs.length < CLOUD_SCHEDULER.circuitFailureThreshold) return false;
  const bad = {failure: true, timed_out: true, startup_failure: true, action_required: true};
  const sha = runs[0].head_sha;
  const repeated = runs.every(function(run) {
    return run.status === 'completed' && bad[run.conclusion] && run.head_sha === sha;
  });
  const key = cloudJobKey_(job).replace(/[^A-Za-z0-9_]/g, '_');
  if (!repeated) {
    props.deleteProperty('CLOUD_CIRCUIT_PROBE_' + key);
    props.deleteProperty('CLOUD_SCHEDULER_ALERT_circuit_' + key);
    return false;
  }

  const lastProbe = Number(props.getProperty('CLOUD_CIRCUIT_PROBE_' + key) || 0);
  if (!lastProbe || now.getTime() - lastProbe >= CLOUD_SCHEDULER.circuitProbeMinutes * 60000) {
    props.setProperty('CLOUD_CIRCUIT_PROBE_' + key, String(now.getTime()));
    return false;
  }
  cloudAlert_('circuit_' + key,
    job.repo + '/' + job.workflow + ' failed ' + runs.length +
    ' consecutive times on commit ' + String(sha).slice(0, 8) +
    '. Automatic retries are limited to one hourly probe until a run succeeds or the code changes.');
  return true;
}

function cloudRefreshReceiptMatches_(receipt, job, process, week) {
  return !!receipt && receipt.season === CLOUD_SCHEDULER.season &&
    String(receipt.league_id) === job.leagueId && receipt.week === week &&
    receipt.status === 'success' && receipt.process === process &&
    (process !== 'corrections' || receipt.bonus_mfl_verified === true);
}

function cloudRefreshComplete_(job, process, week, token, props) {
  if (!week) return false;
  const key = 'CLOUD_REFRESH_COMPLETE_' + process + '_' + job.repo.replace(/[^A-Za-z0-9_]/g, '_') + '_' + week;
  if (process !== 'corrections' && props.getProperty(key) === 'true') return true;
  const receipt = cloudRepoJson_(job.repo, 'data/refresh_receipts/' + process + '.json', token);
  let complete = cloudRefreshReceiptMatches_(receipt, job, process, week);
  if (complete && process === 'corrections') {
    const baseline = cloudRepoJson_(job.repo, 'data/processed_player_scores.json', token);
    const expected = baseline && baseline.season === CLOUD_SCHEDULER.season &&
      String(baseline.league_id) === job.leagueId && baseline.weeks && baseline.weeks[String(week)];
    try { complete = !!expected && expected.digest === cloudPlayerScoreDigest_(job, week); }
    catch (error) {
      console.warn('Direct MFL freshness probe unavailable; the independent GitHub correction checker will verify scores: ' + error.message);
      complete = false;
    }
  }
  if (complete) props.setProperty(key, 'true');
  return complete;
}

function cloudPlayerScoreDigest_(job, week) {
  const response = UrlFetchApp.fetch('https://api.myfantasyleague.com/' + CLOUD_SCHEDULER.season +
    '/export?TYPE=playerScores&L=' + job.leagueId + '&W=' + week + '&JSON=1', {muteHttpExceptions:true});
  if (response.getResponseCode() !== 200) throw new Error('MFL correction freshness check returned HTTP ' + response.getResponseCode());
  const feed = JSON.parse(response.getContentText()).playerScores;
  if (Number(feed && feed.week) !== week) throw new Error('MFL correction freshness check returned the wrong week');
  const rows = Array.isArray(feed.playerScore) ? feed.playerScore : [feed.playerScore];
  const scores = Object.create(null);
  rows.forEach(function(row) {
    if (!row || !row.id || row.score === '' || row.score == null || !Number.isFinite(Number(row.score)) || scores[String(row.id)] !== undefined) throw new Error('Invalid or duplicate MFL player score');
    scores[String(row.id)] = String(Number(row.score));
  });
  if (!Object.keys(scores).length) throw new Error('MFL player-score feed is empty');
  const canonical = '{' + Object.keys(scores).sort().map(function(id) { return JSON.stringify(id) + ':' + JSON.stringify(scores[id]); }).join(',') + '}';
  return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, canonical, Utilities.Charset.UTF_8)
    .map(function(value) { return ('0' + ((value + 256) % 256).toString(16)).slice(-2); }).join('');
}

function auditCloudSchedulerReadOnly() {
  const start = Date.now(), now = new Date(), props = PropertiesService.getScriptProperties();
  const token = props.getProperty(CLOUD_SCHEDULER.tokenProperty);
  if (!token) throw new Error('Scheduler token is not configured');
  const readOnlyProps = {getProperty:function(key) { return props.getProperty(key); }, setProperty:function() {}};
  localJobMatchesDate_.cache = Object.create(null);
  const week = cloudTargetWeek_(now);
  const checks = CLOUD_SCHEDULER.polling.corrections.map(function(job) {
    return {repo:job.repo, week:week, current:cloudRefreshComplete_(job, 'corrections', week, token, readOnlyProps)};
  });
  CLOUD_SCHEDULER.localJobs.forEach(function(job) { latestDueMinute_(job, now, null, localJobMatchesDate_); });
  console.log(JSON.stringify({event:'read_only_scheduler_audit', checks:checks, timezoneConversions:Object.keys(localJobMatchesDate_.cache).length, elapsedMs:Date.now()-start}));
}

function cloudAlert_(key, message) {
  const props = PropertiesService.getScriptProperties();
  const property = 'CLOUD_SCHEDULER_ALERT_' + key.replace(/[^A-Za-z0-9_]/g, '_');
  if (props.getProperty(property) === message) return;
  MailApp.sendEmail(CLOUD_SCHEDULER.alertEmail, 'League cloud scheduler failed: ' + key,
    'The free Apps Script scheduler could not dispatch a required GitHub workflow.\n\n' + message);
  props.setProperty(property, message);
}

function cloudJobKey_(job) {
  const slot = job.cron ||
    (Number.isFinite(job.hour) && Number.isFinite(job.minute) ? job.hour + ':' + job.minute : 'interval');
  return job.repo + '/' + job.workflow + '/' + slot;
}

function dispatchOnce_(job, token, slot, props, overrideInputs) {
  const key = cloudJobKey_(job);
  const receipt = 'CLOUD_SCHEDULER_SENT_' + key.replace(/[^A-Za-z0-9_]/g, '_');
  const slotText = String(slot.getTime());
  if (props.getProperty(receipt) === slotText) {
    console.log('Already dispatched ' + key + ' for ' + slot.toISOString());
    return false;
  }
  try {
    cloudDispatch_(job, token, overrideInputs);
    props.setProperty(receipt, slotText);
    props.deleteProperty('CLOUD_SCHEDULER_ALERT_' + key.replace(/[^A-Za-z0-9_]/g, '_'));
    console.log('Dispatched ' + key + ' for ' + slot.toISOString());
    return true;
  } catch (error) {
    cloudAlert_(key, error.message);
    throw error;
  }
}

function runCloudLeagueScheduler() {
  localJobMatchesDate_.cache = Object.create(null);
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return;
  const props = PropertiesService.getScriptProperties();
  const leaseKey = 'CLOUD_SCHEDULER_EXECUTION_LEASE';
  const owner = String(Date.now()) + '/' + String(Math.random());
  try {
    let lease;
    try { lease = JSON.parse(props.getProperty(leaseKey) || '{}'); } catch (error) { lease = {}; }
    if (Number(lease.until) > Date.now()) return;
    props.setProperty(leaseKey, JSON.stringify({owner:owner, until:Date.now()+8*60000}));
  } finally {
    lock.releaseLock();
  }
  try {
    const now = new Date();
    const token = props.getProperty(CLOUD_SCHEDULER.tokenProperty);
    if (!token) {
      cloudAlert_('credential', 'Missing Apps Script property ' + CLOUD_SCHEDULER.tokenProperty + '.');
      return;
    }
    const previous = props.getProperty('CLOUD_SCHEDULER_LAST_RUN');
    const lastRun = previous ? new Date(Number(previous)) : null;
    const failures = [];
    const attempt = function(job, slot, overrideInputs) {
      try { dispatchOnce_(job, token, slot, props, overrideInputs); }
      catch (error) { failures.push(cloudJobKey_(job) + ': ' + error.message); }
    };
    const intervalMs = CLOUD_SCHEDULER.intervalMinutes * 60000;
    const intervalSlot = new Date(Math.floor(now.getTime() / intervalMs) * intervalMs);
    CLOUD_SCHEDULER.intervalJobs.forEach(function(job) { attempt(job, intervalSlot); });
    const pollingWindow = cloudPollWindow_(now);
    const targetWeek = cloudTargetWeek_(now);
    if (pollingWindow) CLOUD_SCHEDULER.polling[pollingWindow].forEach(function(job) {
      try {
        if (!cloudRefreshComplete_(job, pollingWindow, targetWeek, token, props) &&
            !cloudPollingCircuitOpen_(job, token, props, now) &&
            !cloudWorkflowInFlight_(job, token)) attempt(job, intervalSlot);
      } catch (error) {
        failures.push(cloudJobKey_(job) + ' receipt check: ' + error.message);
      }
    });
    CLOUD_SCHEDULER.cronJobs.forEach(function(job) {
      const due = latestDueMinute_(job, now, lastRun, function(candidateJob, date) {
        return cronMatchesDate_(candidateJob.cron, date);
      });
      if (due) attempt(job, due);
    });
    CLOUD_SCHEDULER.localJobs.forEach(function(job) {
      const due = latestDueMinute_(job, now, lastRun, localJobMatchesDate_);
      if (due) attempt(job, due, cloudLocalInputs_(job, due));
    });
    props.setProperty('CLOUD_SCHEDULER_LAST_RUN', String(now.getTime()));
    if (failures.length) throw new Error(failures.join('\n'));
  } finally {
    const lease = JSON.parse(props.getProperty(leaseKey) || '{}');
    if (lease.owner === owner) props.deleteProperty(leaseKey);
  }
}

function allCloudJobs_() {
  let jobs = CLOUD_SCHEDULER.intervalJobs.concat(CLOUD_SCHEDULER.cronJobs, CLOUD_SCHEDULER.localJobs);
  Object.keys(CLOUD_SCHEDULER.polling).forEach(function(name) { jobs = jobs.concat(CLOUD_SCHEDULER.polling[name]); });
  const seen = {};
  return jobs.filter(function(job) {
    const key = job.repo + '/' + job.workflow;
    if (seen[key]) return false;
    seen[key] = true;
    return true;
  });
}

function verifyCloudSchedulerAccess() {
  const token = PropertiesService.getScriptProperties().getProperty(CLOUD_SCHEDULER.tokenProperty);
  if (!token) throw new Error('Set script property ' + CLOUD_SCHEDULER.tokenProperty + ' first.');
  const jobs = allCloudJobs_();
  jobs.forEach(function(job) { cloudVerifyWorkflow_(job, token); });
  return 'Verified read access to ' + jobs.length + ' recurring GitHub workflows.';
}

function installCloudScheduler() {
  verifyCloudSchedulerAccess();
  ScriptApp.getProjectTriggers().forEach(function(trigger) {
    if (trigger.getHandlerFunction() === 'runCloudGitHubPolls' ||
        trigger.getHandlerFunction() === 'runCloudLeagueScheduler') ScriptApp.deleteTrigger(trigger);
  });
  ScriptApp.newTrigger('runCloudLeagueScheduler').timeBased().everyMinutes(5).create();
  return 'Installed one free 5-minute scheduler for all recurring league workflows.';
}
