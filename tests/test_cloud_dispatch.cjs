const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
let now = 1000000, code = 500, calls = 0, network = false;
const values = {}, emails = [];
const props = {
  getProperty: key => values[key] || null,
  setProperty: (key, value) => { values[key] = value; },
  deleteProperty: key => { delete values[key]; }
};
class Clock extends Date { static now() { return now; } }
const ctx = vm.createContext({Date: Clock, console,
  Utilities: {sleep() {}},
  UrlFetchApp: {fetch() { calls++; if (network) throw Error('timeout');
    return {getResponseCode: () => code, getContentText: () => ''}; }},
  MailApp: {sendEmail: (...args) => emails.push(args)}
});
vm.runInContext(fs.readFileSync('scripts/CloudPolling.gs', 'utf8'), ctx);
const job = {repo: 'test', workflow: 'watch.yml', cron: '7 * * * *'};
const run = () => ctx.dispatchOnce_(job, 'test-token', new Date(now), props);
assert.equal(run(), false);
assert.equal(calls, 4);
assert.equal(emails.length, 0);
assert(!Object.keys(values).some(k => k.startsWith('CLOUD_SCHEDULER_SENT_')));
now += 5 * 60000; network = true;
run(); assert.equal(emails.length, 0);
now += 10 * 60000;
run(); assert.equal(emails.length, 1);
network = false; code = 503; now += 3600000;
run(); assert.equal(emails.length, 1);
code = 204;
assert.equal(run(), true);
assert(!Object.keys(values).some(k => k.startsWith('CLOUD_DISPATCH_INCIDENT_')));
const previous = calls;
assert.equal(run(), false); assert.equal(calls, previous);
now += 3600000; code = 401;
run(); assert.equal(emails.length, 2);
run(); assert.equal(emails.length, 2);
ctx.MailApp.sendEmail = () => { throw Error('mail unavailable'); };
code = 204; run(); now += 3600000; code = 422;
assert.throws(run, /mail unavailable/);
assert(!JSON.parse(Object.entries(values).find(([k]) => k.startsWith('CLOUD_DISPATCH_INCIDENT_'))[1]).alerted);
console.log('Dispatch retry, recovery, deduplication, permanent failure and mail failure tests passed.');
