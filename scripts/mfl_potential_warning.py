"""Owner-only, deduplicated warning for known MFL potential-point anomalies."""
import hashlib
import json

def report_warning(state, dry, document, deliver, save, send):
    report = document('TheMathNinja/ADL-GM-Dashboard', 'data/mfl_potential_warning.json')
    if not report or report.get('status') == 'clear':
        return
    if report.get('policy') != 'mfl-potential-warning-v1' or report.get('league') != 'ADL':
        raise ValueError('Unrecognized MFL potential warning report')
    rows = report['observations']
    if not rows:
        raise ValueError('Empty MFL warning')
    identity = json.dumps([report['season'], rows], sort_keys=True)
    key = 'mfl-potential-warning:' + hashlib.sha256(identity.encode()).hexdigest()
    if key in state['sent']:
        return
    subject = '[ADL warning] MFL potential points below actual points'
    body = ('MFL is reporting potential points below actual points for the observations below. '
            'This known upstream issue is warning-only and does not stop the forecast run. '
            'Reported scores are retained unchanged; no correction was invented. '
            'Forecasts involving potential points may be affected until MFL corrects its data.\n\n'
            f"Season {report['season']}; checked through Week {report['through_week']}.\n" +
            '\n'.join(f"Week {r['week']}, franchise {r['franchise_id']}: actual {r['points']}, potential {r['potential']}" for r in rows))
    if dry:
        print(subject + '\n' + body)
        return
    deliver(state, key, lambda: send(subject, body, key), lambda: save(state))
    state['sent'][key] = {'subject': subject}
    save(state)
