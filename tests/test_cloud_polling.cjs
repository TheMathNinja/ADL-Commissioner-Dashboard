const assert=require('assert'),fs=require('fs'),vm=require('vm');
const source=fs.readFileSync('scripts/CloudPolling.gs','utf8');
const context=vm.createContext({});vm.runInContext(source,context);
const window=(day,clock,year=2026,month=10)=>vm.runInContext(`cloudPollWindowParts_(${day},'${clock}',${year},${month})`,context);
assert.equal(window(1,'23:29'),'');
assert.equal(window(1,'23:30'),'preliminary');
assert.equal(window(2,'23:59'),'preliminary');
assert.equal(window(4,'03:44'),'');
assert.equal(window(4,'03:45'),'corrections');
assert.equal(window(5,'00:00'),'');
assert.equal(window(2,'12:00',2026,8),'');
assert.equal(window(2,'12:00',2027,1),'preliminary');
assert.equal(window(2,'12:00',2027,2),'');
const cron=(expr,m,h,dom,mon,dow)=>vm.runInContext(`cronMatchesUtcParts_('${expr}',${m},${h},${dom},${mon},${dow})`,context);
assert(cron('0 10 * * *',0,10,1,10,4));
assert(!cron('0 10 * * *',1,10,1,10,4));
assert(cron('5 */6 * 9-12,1 *',5,18,1,10,4));
assert(cron('5 */6 * 9-12,1 *',5,0,1,1,4));
assert(!cron('5 */6 * 9-12,1 *',5,1,1,10,4));
assert(!cron('5 */6 * 9-12,1 *',5,18,1,8,4));
assert(cron('7 16 31 8 *',7,16,31,8,1));
assert(!cron('7 16 31 8 *',7,16,30,8,1));
const localInputs=(year,month,day)=>vm.runInContext(`JSON.stringify(cloudLocalInputsParts_({workflow:'update_dashboard.yml',inputs:{enable_mfl_salary_writes:'false'}},${year},${month},${day}))`,context);
assert.equal(localInputs(2026,7,1),'{"enable_mfl_salary_writes":"false"}');
assert.equal(localInputs(2027,6,30),'{"enable_mfl_salary_writes":"false"}');
assert.equal(localInputs(2027,7,1),'{"enable_mfl_salary_writes":"true"}');
const jobs=vm.runInContext('allCloudJobs_().map(j=>j.repo+"/"+j.workflow)',context);
assert.equal(jobs.length,13);
['ADL-GM-Dashboard/poll_preliminary_scores.yml','FAFL-GM-Dashboard/poll_score_corrections.yml',
 'ADL-GM-Dashboard/refresh_rosters.yml','ADL-Commissioner-Dashboard/daily-commissioner-alerts.yml',
 'ADL-Commissioner-Dashboard/offseason-inactivity-monitor.yml','ADL-Commissioner-Dashboard/lineup-designation-snapshots.yml',
 'ADL-Commissioner-Dashboard/waiver-cap-corrections.yml'].forEach(job=>assert(jobs.includes(job),job));
console.log('Cloud league scheduler tests passed.');
