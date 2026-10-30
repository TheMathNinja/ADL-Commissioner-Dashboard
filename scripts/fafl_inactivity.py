"""Lightweight FAFL inactivity checks; no roster or ownership writes."""
import argparse,json,os,time,urllib.parse,urllib.request,xml.etree.ElementTree as ET
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

class MFL:
    def __init__(self,season=2026):
        self.season=season;self.cookie=None;self.host='api.myfantasyleague.com'

    def read(self,url,data=None):
        headers={'User-Agent':'FAFL-Inactivity-Watch/1.0'}
        if self.cookie:headers['Cookie']='MFL_USER_ID='+self.cookie
        request=urllib.request.Request(url,data=urllib.parse.urlencode(data).encode() if data else None,headers=headers)
        with urllib.request.urlopen(request,timeout=25)as response:return response.read().decode('utf-8')

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

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--probe',action='store_true');args=parser.parse_args()
    client=MFL();client.login();league=client.export('league')
    franchises=league['franchises']['franchise']
    print(json.dumps({'franchise_count':len(franchises),'franchise_fields':sorted(set().union(*(row.keys()for row in franchises))),
                      'login_fields_present':{key:sum(bool(row.get(key))for row in franchises)for key in sorted(set().union(*(row.keys()for row in franchises)))if any(word in key.lower()for word in ['visit','login','access'])}}))

if __name__=='__main__':main()
