"""Dispatch and verify a private audit without exposing its source or inputs."""
import argparse,json,os,re,subprocess,time
REPO='TheMathNinja/Chicago-Bears-Lineup-Guardian'

def read_state(run_id, allow_missing):
    try:
        output = subprocess.check_output(
            ['gh', 'api', f'repos/{REPO}/actions/runs/{run_id}'],
            text=True, timeout=30, stderr=subprocess.PIPE)
    except subprocess.TimeoutExpired:
        return None
    except subprocess.CalledProcessError as error:
        status = re.search(r'HTTP (\d{3})', error.stderr or '')
        code = int(status[1]) if status else None
        if code in (429, 500, 502, 503, 504) or (code == 404 and allow_missing):
            return None
        raise
    return json.loads(output)
def run(audit):
    correlation=os.environ['GITHUB_RUN_ID']+'-'+os.environ.get('GITHUB_RUN_ATTEMPT','1')+'-'+audit
    output=subprocess.check_output(['gh','workflow','run','league-audit.yml','--repo',REPO,'-f','audit='+audit,'-f','source_run_id='+correlation],text=True,timeout=45)
    match=re.search(r'https://github\.com/'+re.escape(REPO)+r'/actions/runs/(\d+)',output)
    if not match:raise RuntimeError('Private audit was dispatched but its run ID could not be confirmed; inspect the private workflow before retrying')
    run_id=match[1];url=match[0];print('Private audit: '+url,flush=True)
    started=time.monotonic()
    deadline=started+7*60
    seen=False
    while time.monotonic()<deadline:
        # A newly dispatched run can precede its visibility in the runs API.
        state=read_state(run_id, not seen and time.monotonic()-started<90)
        if state is None:
            print('Private audit status temporarily unavailable; retrying the same run.',flush=True)
            time.sleep(10)
            continue
        seen=True
        if state['status']=='completed':
            if state['conclusion']!='success':raise RuntimeError('Private '+audit+' audit ended with '+str(state['conclusion'])+': '+url)
            print('Private '+audit+' audit passed.');return
        time.sleep(10)
    raise RuntimeError('Private audit did not complete within seven minutes: '+url)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('audit',choices=['contracts','guardian']);run(parser.parse_args().audit)
