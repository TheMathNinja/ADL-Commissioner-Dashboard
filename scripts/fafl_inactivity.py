"""Lightweight FAFL inactivity checks; no roster or ownership writes."""
import argparse,base64,copy,hashlib,http.client,json,os,re,ssl,time,urllib.error,urllib.parse,urllib.request,xml.etree.ElementTree as ET
from datetime import datetime,timedelta,timezone
from email.utils import getaddresses
from html.parser import HTMLParser
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT=Path(__file__).resolve().parents[1]
EASTERN=ZoneInfo('America/New_York')
CONFIG=ROOT/'data/fafl_inactivity/config_2026.json'
STATE_PATH='data/fafl_inactivity/state_2026.json'

def rows(value):return value if isinstance(value,list) else [value] if isinstance(value,dict) else []
def iso(value):return value.astimezone(timezone.utc).isoformat()
def moment(value):
    if value is None or value=='':return None
    result=datetime.fromtimestamp(float(value),timezone.utc) if str(value).isdigit() else datetime.fromisoformat(str(value).replace('Z','+00:00'))
    if result.tzinfo is None:raise ValueError('Timestamp lacks timezone')
    return result
def local(value):return moment(value).astimezone(EASTERN).strftime('%b %d, %Y at %I:%M %p %Z')

class LineupTables(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.stack=[];self.tables=[]
    def handle_starttag(self,tag,attrs):
        if tag=='table':self.stack.append({'caption':[],'text':[],'fid':None,'in_caption':False})
        if not self.stack:return
        current=self.stack[-1]
        if tag=='caption':current['in_caption']=True
        if tag=='a' and current['in_caption']:
            query=urllib.parse.parse_qs(urllib.parse.urlparse(dict(attrs).get('href','')).query)
            current['fid']=(query.get('F') or query.get('FRANCHISE') or [None])[0]
    def handle_data(self,data):
        for frame in self.stack:
            frame['text'].append(data)
            if frame['in_caption']:frame['caption'].append(data)
    def handle_endtag(self,tag):
        if not self.stack:return
        if tag=='caption':self.stack[-1]['in_caption']=False
        if tag=='table':self.tables.append(self.stack.pop())

def parse_lineups(html,season,week):
    parser=LineupTables();parser.feed(html);result={}
    for table in parser.tables:
        if not re.search(r'\bWeek\s+'+str(week)+r'\s+lineup\b',' '.join(table['caption']),re.I):continue
        fid=table['fid']
        if not fid or fid in result:raise ValueError('Missing or duplicate franchise in lineup report')
        text=re.sub(r'\s+',' ',' '.join(table['text']));lower=text.lower()
        missing=any(marker in lower for marker in ('no starting lineup submitted','no lineup submitted','lineup not submitted','lineup copied from previous week',"previous week's lineup"))
        commissioner=any(marker in lower for marker in ('set by commissioner','commissioner-set','set by the commissioner'))
        match=re.search(r'Lineup submitted at\s+([A-Za-z]{3} [A-Za-z]{3} \d{1,2} \d{1,2}:\d{2}(?::\d{2})? [ap]\.m\. (?:ET|EST|EDT) \d{4})',text,re.I)
        stamp=None
        if match:
            raw=re.sub(r'a\.m\.','AM',match[1],flags=re.I);raw=re.sub(r'p\.m\.','PM',raw,flags=re.I);raw=re.sub(r' (ET|EST|EDT) ',' ',raw)
            fmt='%a %b %d %I:%M:%S %p %Y' if raw.count(':')==2 else '%a %b %d %I:%M %p %Y'
            parsed=datetime.strptime(raw,fmt).replace(tzinfo=EASTERN)
            if parsed.year!=season:raise ValueError('Lineup timestamp has wrong season')
            stamp=iso(parsed)
        result[fid]={'status':'missing' if missing else 'review' if commissioner else 'submitted' if stamp else 'unknown','submitted_at':stamp if not missing else None}
    return result

def read_complete_lineups(client,url,season,week,expected,sleep=time.sleep):
    expected=set(expected)
    for attempt in range(3):
        # Retry incomplete successful HTTP responses, not just transport errors.
        target=url if not attempt else url+'&_inactivity_retry='+str(time.time_ns())
        parsed=parse_lineups(client.read(target),season,week)
        if set(parsed)==expected:return parsed
        missing=sorted(expected-set(parsed));unexpected=sorted(set(parsed)-expected)
        print(f'Week {week} lineup coverage attempt {attempt+1}/3: {len(parsed)}/{len(expected)} teams; missing={missing}; unexpected={unexpected}')
        if attempt<2:sleep(2*(attempt+1))
    raise ValueError(f'Incomplete Week {week} lineup report after 3 attempts; no inactivity conclusions were issued')

def week_windows(schedule):
    result={}
    for row in rows(schedule['fullNflSchedule']['nflSchedule']):
        week=int(row['week'])
        if not 1<=week<=17:continue
        starts=[moment(game['kickoff'])for game in rows(row.get('matchup'))if str(game.get('kickoff','')).isdigit()]
        if not starts:raise ValueError('Missing kickoff times for Week '+str(week))
        first=min(starts);day=first.astimezone(EASTERN).date()
        monday=day+timedelta(days=(7-day.weekday())%7)
        close=datetime(monday.year,monday.month,monday.day,23,tzinfo=EASTERN)
        result[week]={'first':first,'close':max(close,max(starts)+timedelta(seconds=1))}
    if set(result)!=set(range(1,18)):raise ValueError('NFL schedule must cover all 17 monitored weeks')
    return result

def owner_key(franchise):
    identity=franchise.get('username') or franchise.get('email')
    if not identity:raise ValueError('Missing stable owner identity')
    return hashlib.sha256(str(identity).strip().lower().encode()).hexdigest()[:20]

def recipient_addresses(value):
    addresses=sorted({email.lower()for _,email in getaddresses([str(value)])if email})
    if not addresses or any(not re.fullmatch(r'[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+',email)for email in addresses):raise ValueError('Missing or invalid email recipient')
    return addresses

def commissioner_addresses(franchises):
    selected=[]
    for prefix in ('filicicchia','russ','tim'):
        matches=[f for f in franchises if prefix in f.get('owner_name','').lower().split() or any(word.startswith(prefix)for word in f.get('owner_name','').lower().split())]
        emails={email for f in matches for email in recipient_addresses(f.get('email',''))}
        if len(emails)!=1:raise ValueError('Cannot uniquely verify commissioner contact for '+prefix)
        selected.extend(emails)
    if len(set(selected))!=3:raise ValueError('Expected exactly three distinct FAFL commissioners')
    return sorted(selected)

def evaluate(state,franchises,lineups,windows,bids,config,now):
    state=copy.deepcopy(state);state.setdefault('schema',1);state.setdefault('incidents',{});state.setdefault('counts',{});state.setdefault('audited_weeks',[])
    state.setdefault('activated_at',iso(now));state.setdefault('owners',{});coverage=[]
    current=next((week for week in sorted(windows)if now<windows[week]['close']),17)
    active_season=windows[1]['first']<=now<=windows[17]['close']
    auction=config['initial_auction'];auction_active=bool(auction.get('starts_at') and auction.get('ends_at') and moment(auction['starts_at'])<=now<moment(auction['ends_at']))
    def issue(f,rule,episode,observed,activity_at=None):
        key=f['id']+':'+owner_key(f)+':'+rule+':'+str(episode)
        if key not in state['incidents']:
            count_key=f['id']+':'+owner_key(f)+':'+rule
            state['counts'][count_key]=state['counts'].get(count_key,0)+1
            count=state['counts'][count_key]
            state['incidents'][key]={'franchise_id':f['id'],'franchise':f['name'],'owner_key':owner_key(f),'rule':rule,'episode':episode,'count':count,'observed':observed,'detected_at':iso(now),'status':'review' if rule in ('auction','lineup')and count>=2 else 'pending_notice','activity_at':activity_at}
    closed=[week for week in windows if week>=config['lineup_tracking_from_week'] and windows[week]['close']<=now and week not in state['audited_weeks']]
    for f in franchises:
        fid=f['id']
        identity=owner_key(f);prior=state['owners'].get(fid,{})
        if prior.get('key')!=identity:
            state['owners'][fid]={'key':identity,'changed_at':iso(now)if prior else None}
        changed_at=moment(state['owners'][fid].get('changed_at'))
        login=None
        if active_season or auction_active:
            try:login=moment(f.get('lastVisit'))
            except (ValueError,TypeError,OverflowError):pass
            if login is None or login>now or login.year<config['season']:
                coverage.append(fid+': login timestamp unavailable');login=None
            elif now-max(login,changed_at or login)>=timedelta(days=7):issue(f,'login',int(login.timestamp()),'Last league access: '+local(iso(login)),iso(login))
        for week in closed:
            if changed_at and windows[week]['close']<=changed_at:continue
            entry=lineups.get(week,{}).get(fid,{})
            if entry.get('status')=='missing':issue(f,'lineup',week,f'No owner-submitted Week {week} lineup; MFL may have inherited a lineup')
            elif entry.get('status')!='submitted':coverage.append(fid+f': Week {week} submission status unavailable/requires review')
        if auction_active:
            if bids is None:coverage.append(fid+': complete auction bid history unavailable')
            else:
                last=max([moment(auction['starts_at'])]+[moment(t['timestamp'])for t in bids if t.get('franchise')==fid and moment(auction['starts_at'])<=moment(t['timestamp'])<=now])
                if now-last>=timedelta(hours=24):issue(f,'auction',int(last.timestamp()),'No auction bid in the last 24 hours; last bid/window start: '+local(iso(last)),iso(last))
        for incident in state['incidents'].values():
            if incident['franchise_id']!=fid or incident['owner_key']!=owner_key(f) or incident['status'] in ('resolved','resolved_late','retired_owner'):continue
            activity=None
            if incident['rule']=='login' and login and login>moment(incident['activity_at']):activity=login
            if incident['rule']=='auction' and bids is not None:
                activity=min([moment(t['timestamp'])for t in bids if t.get('franchise')==fid and moment(t['timestamp'])>moment(incident['activity_at'])],default=None)
            if incident['rule']=='lineup':
                activity=min([moment(values[fid]['submitted_at'])for week,values in lineups.items() if week>=incident['episode'] and values.get(fid,{}).get('status')=='submitted' and moment(values[fid]['submitted_at'])>moment(incident['detected_at'])],default=None)
            if activity and activity<=now:
                late=bool(incident.get('deadline') and activity>moment(incident['deadline']))
                incident.update(status='review' if incident['status']=='review' else 'resolved_late' if late else 'resolved',resolved_at=iso(activity))
            else:
                known=login is not None if incident['rule']=='login' else bids is not None if incident['rule']=='auction' else lineups.get(current,{}).get(fid,{}).get('status')=='missing'
                if not known:coverage.append(fid+': '+incident['rule']+' rectification cannot currently be verified')
                elif incident.get('deadline') and now>=moment(incident['deadline']):incident['status']='overdue'
    for incident in state['incidents'].values():
        f=next((f for f in franchises if f['id']==incident['franchise_id']),None)
        if f and incident['owner_key']!=owner_key(f):incident['status']='retired_owner'
    for week in closed:
        if all(lineups.get(week,{}).get(f['id'],{}).get('status')in('missing','submitted')for f in franchises):state['audited_weeks'].append(week)
    state['coverage']=sorted(set(coverage));state['last_checked_at']=iso(now)
    return state

def incident_details(incident,now):
    rule=incident['rule']
    if rule=='login':
        days=max(0,int((now-moment(incident['activity_at'])).total_seconds()//86400))
        return ['Rule violated: No league login for 7 consecutive days.',
                'Last league access: '+local(incident['activity_at'])+f' ({days} days ago)']
    if rule=='lineup':return [f'Rule violated: No lineup submitted for Week {incident["episode"]}.']
    return ['Rule violated: No auction bid during a 24-hour period in the initial auction.',incident['observed']]

def remedy_sentence(rule,deadline):
    action={'login':'log in to the FAFL league','lineup':'submit your current weekly FAFL lineup','auction':'submit an auction bid'}[rule]
    return 'Please '+action+' by '+local(deadline)+'.'

def digest_incident_lines(incident,now):
    lines=[incident['franchise']]+incident_details(incident,now)
    status=incident['status']
    if status in ('resolved','resolved_late'):
        lines.append('The owner has addressed this issue'+(' after the warning deadline.' if status=='resolved_late' else '.'))
    elif status=='retired_owner':lines.append('This warning belonged to a previous owner and no longer applies to the current owner.')
    elif status=='overdue':lines.append('The warning deadline has passed: '+local(incident['deadline'])+'.')
    elif status=='review':lines.append('This is a repeat '+incident['rule']+' violation; commissioner review is required under the bylaws.')
    elif incident.get('deadline'):lines.append(remedy_sentence(incident['rule'],incident['deadline']))
    else:lines.append('The owner warning has not been confirmed sent; the response period has not started.')
    if incident.get('resolved_at'):lines.append('Issue addressed: '+local(incident['resolved_at']))
    if status in ('overdue','review','resolved_late'):lines.append('Commissioners must review the applicable forfeiture policy. No ownership or winnings changes have been made automatically.')
    return lines+['']

def owner_message(incident,deadline):
    title='FAFL Inactivity Watch - '+incident['franchise']
    lines=[title,'']+incident_details(incident,moment(incident.get('detected_at')) or datetime.now(timezone.utc))+['']
    if incident['count']>=2 and incident['rule']in('auction','lineup'):
        lines+=['This is the second '+incident['rule']+' infraction this season. The bylaws provide for forfeiture without an additional warning period. The commissioners have been notified to review and administer the policy.']
    else:
        lines+=['You are on inactivity watch under the FAFL bylaws.',remedy_sentence(incident['rule'],deadline),
                'The deadline runs from this warning: '+('24 hours.' if incident['rule']=='auction' else '120 hours / five days.'),
                'If not rectified within that period, the bylaws provide for forfeiture of franchise management and subsequent winnings. Commissioners will review the evidence and handle any replacement; this system does not remove an owner.']
    return title,'\n'.join(lines)

class MFL:
    def __init__(self,season=2026):
        self.season=season;self.cookie=None;self.host='api.myfantasyleague.com'

    def read(self,url,data=None):
        headers={'User-Agent':'FAFL-Inactivity-Watch/1.0'}
        if self.cookie:headers['Cookie']='MFL_USER_ID='+self.cookie
        request=urllib.request.Request(url,data=urllib.parse.urlencode(data).encode() if data else None,headers=headers)
        for attempt in range(2 if data is None else 1):
            try:
                with urllib.request.urlopen(request,timeout=20)as response:return response.read().decode('utf-8')
            except (OSError,urllib.error.URLError,http.client.HTTPException)as error:
                code=getattr(error,'code',None)
                transient=code in (500,502,503,504) if code is not None else not isinstance(getattr(error,'reason',error),ssl.SSLCertVerificationError)
                if data is not None or attempt or not transient:raise
                time.sleep(2)

    def login(self):
        raw=self.read(f'https://api.myfantasyleague.com/{self.season}/login',{'USERNAME':os.environ['MFL_USERNAME'],'PASSWORD':os.environ['MFL_PASSWORD'],'XML':'1'})
        tree=ET.fromstring(raw)
        value=next((node.attrib['MFL_USER_ID'] for node in tree.iter() if 'MFL_USER_ID' in node.attrib),None)
        if not value:raise ValueError('MFL authentication failed; response and credentials are deliberately not logged')
        self.cookie=urllib.parse.quote(urllib.parse.unquote(value),safe='')

    def export(self,kind,**params):
        time.sleep(1)
        query=urllib.parse.urlencode({'TYPE':kind,'L':'22686','JSON':'1',**params})
        result=json.loads(self.read(f'https://{self.host}/{self.season}/export?'+query))
        if kind not in result:raise ValueError('MFL '+kind+' data unavailable')
        return result[kind]

def deliver_owner_notices(updated,franchises,send,save,clock=lambda:datetime.now(timezone.utc),commissioners=None):
    problems=[]
    for key,incident in updated['incidents'].items():
        if incident['status']not in ('pending_notice','review')or incident.get('notice'):continue
        franchise=next(f for f in franchises if f['id']==incident['franchise_id'])
        try:recipients=recipient_addresses(franchise.get('email',''))
        except ValueError:
            problems.append(incident['franchise']+': owner email unavailable');continue
        issued=clock();deadline=iso(issued+timedelta(hours=24 if incident['rule']=='auction' else 120))
        title,body=owner_message(incident,deadline)
        incident['notice']={'status':'sending','attempted_at':iso(issued)};save()
        try:send(title,body,'fafl-inactivity:'+key,to=','.join(recipients),**({'cc':','.join(commissioners)} if commissioners else {}))
        except Exception:
            incident['notice']['status']='delivery_uncertain';save();problems.append(incident['franchise']+': owner email delivery uncertain; commissioner review required');break
        incident['notice'].update(status='accepted',issued_at=iso(issued))
        if incident['status']!='review':incident.update(status='watch',deadline=deadline)
        save()
    for incident in updated['incidents'].values():
        if incident.get('notice',{}).get('status')in('sending','delivery_uncertain'):problems.append(incident['franchise']+': owner notice requires delivery review; no grace deadline is running')
    return sorted(set(problems))


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--probe',action='store_true');parser.add_argument('--dry-run',action='store_true');args=parser.parse_args()
    config=json.loads(CONFIG.read_text())
    if not config['enabled']:print('FAFL inactivity monitoring disabled');return
    auction=config['initial_auction']
    if bool(auction.get('starts_at'))!=bool(auction.get('ends_at')):raise ValueError('Both initial-auction boundary dates are required')
    if auction.get('starts_at') and moment(auction['starts_at'])>=moment(auction['ends_at']):raise ValueError('Invalid initial-auction window')
    import email_weekly_completion as mail
    repo=os.environ.get('GITHUB_REPOSITORY','TheMathNinja/ADL-Commissioner-Dashboard')
    state={} if args.probe else mail.document(repo,STATE_PATH)or{}
    now=datetime.now(timezone.utc)
    if os.environ.get('EVENT_NAME')=='schedule' and not args.dry_run and state.get('last_checked_at') and now-moment(state['last_checked_at'])<timedelta(minutes=50):
        print('Hourly cloud check completed recently; independent GitHub backup has nothing to recover');return
    client=MFL(config['season']);client.login();league=client.export('league')
    franchises=rows(league['franchises']['franchise'])
    if {row['id']for row in franchises}!={f'{i:04}'for i in range(1,33)} or len(franchises)!=32:raise ValueError('FAFL franchise coverage must contain all 32 teams exactly once')
    host=urllib.parse.urlparse(league['baseURL']).hostname
    if not host or not host.endswith('.myfantasyleague.com'):raise ValueError('Unexpected MFL league host')
    client.host=host
    commissioners=commissioner_addresses(franchises)
    if args.probe:
        print(json.dumps({'franchise_count':len(franchises),'franchise_fields':sorted(set().union(*(row.keys()for row in franchises))),
                          'numeric_login_timestamps':sum(str(row.get('lastVisit','')).isdigit()for row in franchises),'commissioner_recipients_verified':len(commissioners),
                          'commissioner_name_matches':[{'id':row['id'],'owner':row.get('owner_name','')}for row in franchises if any(word in row.get('owner_name','').lower()for word in ['russ','tim','filicicchia'])]}));return
    schedule=json.loads(client.read(f'https://api.myfantasyleague.com/fflnetdynamic{config["season"]}/nfl_sched.json'))
    windows=week_windows(schedule);current=next((week for week in sorted(windows)if now<windows[week]['close']),17)
    needed={current}|{week for week in windows if week>=config['lineup_tracking_from_week'] and windows[week]['close']<=now and week not in state.get('audited_weeks',[])}
    lineups={}
    for week in sorted(needed):
        lineups[week]=read_complete_lineups(client,f'https://{host}/{config["season"]}/options?L=22686&O=06&W={week}',config['season'],week,{f['id']for f in franchises})
        time.sleep(1)
    bids=None
    if auction.get('starts_at') and moment(auction['starts_at'])<=now<moment(auction['ends_at']):
        feed=client.export('transactions',TRANS_TYPE='AUCTION_INIT,AUCTION_BID',DAYS=999)
        bids=rows(feed.get('transaction'))
        if any(t.get('type')not in ('AUCTION_INIT','AUCTION_BID')or t.get('franchise')not in {f['id']for f in franchises}or not str(t.get('timestamp','')).isdigit()for t in bids):raise ValueError('Auction bid history cannot be verified')
    updated=evaluate(state,franchises,lineups,windows,bids,config,now)
    print(json.dumps({'mode':'dry-run'if args.dry_run else'live','franchises_checked':32,'week':current,'lineup_tracking_from_week':config['lineup_tracking_from_week'],'auction_active':bids is not None,'coverage':updated['coverage'],
                      'incidents':[dict(franchise=i['franchise'],rule=i['rule'],count=i['count'],status=i['status'],observed=i['observed'])for i in updated['incidents'].values()]}))
    if args.dry_run:return
    def save():
        url=f'https://api.github.com/repos/{repo}/contents/{STATE_PATH}'
        old=mail.get_json(url)
        payload={'message':'Record FAFL inactivity watch state','branch':'main','content':base64.b64encode((json.dumps(updated,indent=2)+'\n').encode()).decode()}
        if old:payload['sha']=old['sha']
        mail.get_json(url,payload,method='PUT')
    save()
    delivery_problems=deliver_owner_notices(updated,franchises,mail.send_email,save,commissioners=commissioners)
    # Owner warnings already copy commissioners; only unresolved operational or
    # overdue issues need a separate commissioner action email.
    action_incidents={key:value for key,value in updated['incidents'].items() if value['status'] in ('overdue','resolved_late')}
    summary={'incidents':action_incidents,'coverage':updated['coverage'],'delivery_problems':sorted(set(delivery_problems))}
    signature=hashlib.sha256(json.dumps(summary,sort_keys=True).encode()).hexdigest()
    actionable=bool(summary['incidents']or summary['coverage']or summary['delivery_problems'])
    if actionable and signature!=updated.get('digest_signature'):
        lines=['FAFL Inactivity Watch','Checked: '+local(iso(now)),'']
        for incident in action_incidents.values():
            lines += digest_incident_lines(incident,now)
        if summary['coverage']:lines += ['Source coverage requiring review:']+summary['coverage']+['']
        if summary['delivery_problems']:lines += ['Notification delivery requiring review:']+summary['delivery_problems']+['']
        mail.send_email('FAFL Inactivity Watch - Action Required','\n'.join(lines),'fafl-inactivity-action:'+signature,to=','.join(commissioners))
        updated['digest_signature']=signature;save()
    print('FAFL inactivity check completed; no roster, lineup, ownership or winnings changes were made')
    if delivery_problems:raise RuntimeError('An inactivity notice needs delivery review; commissioners were notified')

if __name__=='__main__':main()
