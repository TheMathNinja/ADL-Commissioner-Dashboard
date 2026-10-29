const fs=require('fs'),vm=require('vm'),assert=require('assert'),crypto=require('crypto'),zlib=require('zlib');
const c=vm.createContext({Utilities:{DigestAlgorithm:{SHA_256:'sha256'},Charset:{UTF_8:'utf8'},computeDigest:(a,s)=>[...crypto.createHash(a).update(s).digest()]}});
vm.runInContext(fs.readFileSync('scripts/CloudPolling.gs','utf8'),c);
const fixtures=JSON.parse(zlib.inflateSync(Buffer.from(fs.readFileSync(process.argv[2],'utf8').trim(),'base64')).toString());
for(const f of fixtures){c.UrlFetchApp={fetch:()=>({getResponseCode:()=>200,getContentText:()=>JSON.stringify(f.feed)})};assert.equal(vm.runInContext('cloudPlayerScoreDigest_({leagueId:"'+f.league+'"},7)',c),f.digest);console.log('Cloud/Python digest parity passed for league',f.league);}
