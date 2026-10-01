// Free cloud scheduler for every recurring ADL and FAFL GitHub workflow.
// Install one Apps Script time trigger with installCloudScheduler().
const CLOUD_SCHEDULER = {
  season: 2026,
  easternTimezone: 'America/New_York',
  tokenProperty: 'GITHUB_WORKFLOW_TOKEN',
  alertEmail: 'fili.mikey@gmail.com',
  owner: 'TheMathNinja',
  maxCatchUpMinutes: 26 * 60,
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
  // One hourly safety pass supplements immediate event-driven failure reports.
  cronJobs: [
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'email_workflow_failures.yml', cron: '7 * * * *', inputs: {dry_run: 'false'}}
  ],
  // Fixed local times stay stable across daylight-saving changes.
  localJobs: [
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'update_dashboard.yml', timezone: 'America/New_York', hour: 5, minute: 17, inputs: {enable_mfl_salary_writes: 'false'}},
    {repo: 'ADL-GM-Dashboard', workflow: 'refresh_rosters.yml', timezone: 'America/New_York', hour: 6, minute: 0, inputs: {reason: 'cloud-schedule'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'daily-commissioner-alerts.yml', timezone: 'America/New_York', hour: 6, minute: 15, inputs: {send_email: 'true'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'waiver-cap-corrections.yml', timezone: 'America/New_York', hour: 8, minute: 45, inputs: {send_email: 'true', write_sheet: 'true', verify_sheet_only: 'false'}},
    {repo: 'ADL-Commissioner-Dashboard', workflow: 'dashboard_watchdog.yml', timezone: 'America/New_York', hour: 11, minute: 30, inputs: {}},
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
  if (day === 1 && clock >= '23:30' || day === 2) return 'preliminary';
  if (day === 4 && clock >= '03:45') return 'corrections';
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
  return localJobMatchesParts_(job,
    Number(Utilities.formatDate(date, job.timezone, 'yyyy')),
    Number(Utilities.formatDate(date, job.timezone, 'M')),
    Number(Utilities.formatDate(date, job.timezone, 'd')),
    Number(Utilities.formatDate(date, job.timezone, 'H')),
    Number(Utilities.formatDate(date, job.timezone, 'm')));
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
  if (job.workflow === 'update_dashboard.yml' && year >= 2027 && month === 7 && day === 1) {
    return {enable_mfl_salary_writes: 'true'};
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
  const start = Math.max(fallbackStart, lastRun ? lastRun.getTime() + 60000 : end - 20 * 60000);
  for (let stamp = end; stamp >= start; stamp -= 60000) {
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
  const response = UrlFetchApp.fetch(
    'https://api.github.com/repos/' + CLOUD_SCHEDULER.owner + '/' + job.repo +
      '/actions/workflows/' + job.workflow + '/dispatches',
    {method: 'post', headers: cloudHeaders_(token), contentType: 'application/json',
      payload: JSON.stringify({ref: 'main', inputs: inputs}), muteHttpExceptions: true}
  );
  const code = response.getResponseCode();
  if (code !== 200 && code !== 204) {
    throw new Error(job.repo + '/' + job.workflow + ' returned HTTP ' + code + ': ' +
      response.getContentText().slice(0, 500));
  }
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

function cloudRefreshReceiptMatches_(receipt, job, process, week) {
  return !!receipt && receipt.season === CLOUD_SCHEDULER.season &&
    String(receipt.league_id) === job.leagueId && receipt.week === week &&
    receipt.status === 'success' && receipt.process === process &&
    (process !== 'corrections' || receipt.bonus_mfl_verified === true);
}

function cloudRefreshComplete_(job, process, week, token, props) {
  if (!week) return false;
  const key = 'CLOUD_REFRESH_COMPLETE_' + process + '_' + job.repo.replace(/[^A-Za-z0-9_]/g, '_') + '_' + week;
  if (props.getProperty(key) === 'true') return true;
  const receipt = cloudRepoJson_(job.repo, 'data/refresh_receipts/' + process + '.json', token);
  const complete = cloudRefreshReceiptMatches_(receipt, job, process, week);
  if (complete) props.setProperty(key, 'true');
  return complete;
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
  return job.repo + '/' + job.workflow + '/' + (job.cron || (job.hour + ':' + job.minute) || 'interval');
}

function dispatchOnce_(job, token, slot, props, overrideInputs) {
  const key = cloudJobKey_(job);
  const receipt = 'CLOUD_SCHEDULER_SENT_' + key.replace(/[^A-Za-z0-9_]/g, '_');
  const slotText = String(slot.getTime());
  if (props.getProperty(receipt) === slotText) return false;
  try {
    cloudDispatch_(job, token, overrideInputs);
    props.setProperty(receipt, slotText);
    props.deleteProperty('CLOUD_SCHEDULER_ALERT_' + key.replace(/[^A-Za-z0-9_]/g, '_'));
    return true;
  } catch (error) {
    cloudAlert_(key, error.message);
    throw error;
  }
}

function runCloudLeagueScheduler() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return;
  try {
    const now = new Date();
    const props = PropertiesService.getScriptProperties();
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
    const intervalSlot = new Date(Math.floor(now.getTime() / (15 * 60000)) * 15 * 60000);
    CLOUD_SCHEDULER.intervalJobs.forEach(function(job) { attempt(job, intervalSlot); });
    const pollingWindow = cloudPollWindow_(now);
    const targetWeek = cloudTargetWeek_(now);
    if (pollingWindow) CLOUD_SCHEDULER.polling[pollingWindow].forEach(function(job) {
      try {
        if (!cloudRefreshComplete_(job, pollingWindow, targetWeek, token, props)) attempt(job, intervalSlot);
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
    lock.releaseLock();
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
  ScriptApp.newTrigger('runCloudLeagueScheduler').timeBased().everyMinutes(15).create();
  return 'Installed one free 15-minute scheduler for all recurring league workflows.';
}
