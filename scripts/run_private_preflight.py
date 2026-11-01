"""Dispatch and verify a private audit without exposing its source or inputs."""
import argparse,json,os,re,subprocess,time
REPO='TheMathNinja/Chicago-Bears-Lineup-Guardian'
def run(audit):
    correlation=os.environ['GITHUB_RUN_ID']+'-'+os.environ.get('GITHUB_RUN_ATTEMPT','1')+'-'+audit
    output=subprocess.check_output(['gh','workflow','run','league-audit.yml','--repo',REPO,'-f','audit='+audit,'-f','source_run_id='+correlation],text=True,timeout=45)
    match=re.search(r'https://github\.com/'+re.escape(REPO)+r'/actions/runs/(\d+)',output)
    if not match:raise RuntimeError('Private audit was dispatched but its run ID could not be confirmed; inspect the private workflow before retrying')
    run_id=match[1];url=match[0];print('Private audit: '+url,flush=True)
    deadline=time.monotonic()+7*60
    while time.monotonic()<deadline:
        state=json.loads(subprocess.check_output(['gh','api',f'repos/{REPO}/actions/runs/{run_id}'],text=True,timeout=30))
        if state['status']=='completed':
            if state['conclusion']!='success':raise RuntimeError('Private '+audit+' audit ended with '+str(state['conclusion'])+': '+url)
            print('Private '+audit+' audit passed.');return
        time.sleep(10)
    raise RuntimeError('Private audit did not complete within seven minutes: '+url)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('audit',choices=['contracts','guardian']);run(parser.parse_args().audit)
