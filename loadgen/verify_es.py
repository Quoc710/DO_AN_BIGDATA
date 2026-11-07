import argparse, json, time, urllib.request
from pathlib import Path

def post(url, payload):
    req=urllib.request.Request(url, data=json.dumps(payload).encode(), headers={'Content-Type':'application/json'}, method='POST')
    with urllib.request.urlopen(req, timeout=30) as r: return json.loads(r.read())

def main():
    ap=argparse.ArgumentParser(description='Wait for Spark/Elasticsearch drain and calculate silent loss for HTTP 2xx IDs.')
    ap.add_argument('--run-id', required=True)
    ap.add_argument('--accepted-file', required=True, help='accepted-<run-id>.txt created by LoadGen')
    ap.add_argument('--es', default='http://localhost:9200')
    ap.add_argument('--index', default='app-logs')
    ap.add_argument('--timeout-seconds', type=int, default=180)
    args=ap.parse_args()
    ids=[int(x) for x in Path(args.accepted_file).read_text(encoding='utf-8').splitlines() if x.strip()]
    docs=[]
    for i in range(0,len(ids),500):
        docs.extend({'_index':args.index,'_id':f'{args.run_id}:{n}'} for n in ids[i:i+500])
    deadline=time.monotonic()+args.timeout_seconds
    found=set()
    # Poll at most 500 IDs per round. The timeout prevents a lost record from hanging the run.
    while time.monotonic()<deadline and len(found)<len(docs):
        for i in range(0,len(docs),500):
            part=docs[i:i+500]
            if all(x['_id'] in found for x in part): continue
            result=post(args.es+'/_mget', {'docs':part})
            found.update(x['_id'] for x in result.get('docs',[]) if x.get('found'))
        if len(found)<len(docs): time.sleep(1)
    accepted=len(ids); saved=len(found); lost=accepted-saved
    pct=(lost/accepted*100) if accepted else 0.0
    print(f'run_id={args.run_id}')
    print(f'http_2xx={accepted}')
    print(f'saved_and_queryable={saved}')
    print(f'silent_loss={lost} ({pct:.4f}%)')
    print(f'drain_complete={str(saved==accepted).lower()}')
    if saved<accepted: print(f'pending_or_lost_after_timeout={saved}/{accepted} became queryable within {args.timeout_seconds}s')

if __name__=='__main__': main()
