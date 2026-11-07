import argparse, csv, json, time, urllib.request
from datetime import datetime
from pathlib import Path

def call(url, method='GET', payload=None):
    data=None if payload is None else json.dumps(payload).encode()
    req=urllib.request.Request(url,data=data,headers={} if data is None else {'Content-Type':'application/json'},method=method)
    with urllib.request.urlopen(req,timeout=90) as r: return json.loads(r.read())

def props(path): return dict(x.split('=',1) for x in Path(path).read_text(encoding='utf-8').splitlines() if '=' in x)
def ids(path,lo,hi):
    p=Path(path)
    return {int(x) for x in p.read_text(encoding='utf-8').splitlines() if x.strip() and lo<=int(x)<=hi} if p.exists() else set()
def epoch_ms(v):
    if isinstance(v,(int,float)): return int(v)
    return int(datetime.fromisoformat(v.replace('Z','+00:00')).timestamp()*1000)
def percentile(sorted_values,p):
    if not sorted_values: return None
    pos=(len(sorted_values)-1)*p; lo=int(pos); hi=min(lo+1,len(sorted_values)-1)
    return sorted_values[lo]+(sorted_values[hi]-sorted_values[lo])*(pos-lo)
def save_row(path,row):
    cols=list(row); p=Path(path); p.parent.mkdir(parents=True,exist_ok=True); exists=p.exists()
    with p.open('a',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=cols)
        if not exists: w.writeheader()
        w.writerow(row)
def main():
    ap=argparse.ArgumentParser(description='Compute report metrics after the common 60-second pipeline drain window.')
    ap.add_argument('--run-id',required=True); ap.add_argument('--rate',type=int,required=True)
    ap.add_argument('--es',default='http://localhost:9200'); ap.add_argument('--index',default=None)
    ap.add_argument('--wait-drain',action='store_true',help='wait until LoadGen exit + 60 seconds + 2 seconds for refresh')
    args=ap.parse_args(); args.index=args.index or 'app-logs-'+args.run_id.lower(); meta=props(f'run-{args.run_id}.properties')
    rate=int(meta['rate'])
    if rate!=args.rate: raise SystemExit(f'Rate mismatch: metadata={rate}, argument={args.rate}')
    lo=30*rate+1; hi=90*rate; expected=60*rate
    accepted=ids(f'accepted-{args.run_id}.txt',lo,hi); failed=ids(f'failed-{args.run_id}.txt',lo,hi); skipped=ids(f'skipped-{args.run_id}.txt',lo,hi)
    deadline=int(meta['finish_epoch_ms'])+60_000
    if args.wait_drain:
        wait=(deadline+2_000-int(time.time()*1000))/1000
        if wait>0: print(f'Waiting {wait:.1f}s: 60-second drain plus 2-second Elasticsearch refresh margin'); time.sleep(max(0,wait))
    query={'bool':{'filter':[{'term':{'run_id':args.run_id}},{'range':{'log_id':{'gte':lo,'lte':hi}}},{'range':{'stored_ts':{'lte':deadline}}}]}}
    # Scroll all matching documents so p50/p95/p99 use the same exact interpolation as PostgreSQL percentile_cont.
    page=call(args.es+f'/{args.index}/_search?scroll=2m',method='POST',payload={'size':5000,'_source':['sent_ts','stored_ts'],'query':query})
    sid=page.get('_scroll_id'); latencies=[]; saved_total=0
    while True:
        hits=page.get('hits',{}).get('hits',[])
        if not hits: break
        for h in hits:
            src=h['_source']; latencies.append(epoch_ms(src['stored_ts'])-epoch_ms(src['sent_ts'])); saved_total+=1
        page=call(args.es+'/_search/scroll',method='POST',payload={'scroll':'2m','scroll_id':sid}); sid=page.get('_scroll_id',sid)
    if sid:
        try: call(args.es+'/_search/scroll',method='DELETE',payload={'scroll_id':[sid]})
        except Exception: pass
    latencies.sort()
    late_total=call(args.es+f'/{args.index}/_count',method='POST',payload={'query':{'bool':{'filter':[{'term':{'run_id':args.run_id}},{'range':{'log_id':{'gte':lo,'lte':hi}}},{'range':{'stored_ts':{'gt':deadline}}}]}}})['count']
    saved_accepted=0; late_accepted=0
    accepted_sorted=sorted(accepted)
    for off in range(0,len(accepted_sorted),500):
        result=call(args.es+f'/{args.index}/_mget',method='POST',payload={'docs':[{'_id':f'{args.run_id}:{n}'} for n in accepted_sorted[off:off+500]]})
        for d in result.get('docs',[]):
            if d.get('found'):
                ts=epoch_ms(d['_source']['stored_ts'])
                if ts<=deadline: saved_accepted+=1
                else: late_accepted+=1
    silent_lost=max(0,len(accepted)-saved_accepted); silent_pct=100*silent_lost/len(accepted) if accepted else 0
    missing=max(0,expected-saved_total); total_loss=100*missing/expected if expected else 0
    row={'run_id':args.run_id,'rate':rate,'can_nhan':expected,'da_luu':saved_total,'ti_le_mat_pct':f'{total_loss:.3f}',
         'throughput_log_per_s':f'{saved_total/60:.1f}','p50_ms':'' if not latencies else f'{percentile(latencies,.50):.1f}',
         'p95_ms':'' if not latencies else f'{percentile(latencies,.95):.1f}','p99_ms':'' if not latencies else f'{percentile(latencies,.99):.1f}',
         'max_ms':'' if not latencies else f'{latencies[-1]:.1f}'}
    save_row(str(Path(__file__).resolve().parents[1]/'ket-qua'/'tong-hop-pipeline.csv'),row)
    print(f'run_id={args.run_id}; offered={rate} logs/s; measured log_id={lo}..{hi}')
    print(f'expected={expected}; saved_by_deadline={saved_total}; throughput={saved_total/60:.1f} logs/s; total_loss={total_loss:.3f}%')
    print(f'HTTP 2xx={len(accepted)}; visible errors/timeouts={len(failed)}; sender skipped={len(skipped)}')
    print(f'saved from HTTP-2xx IDs={saved_accepted}; silent_loss={silent_lost}/{len(accepted)} ({silent_pct:.4f}%)')
    print(f'late after 60s drain: all={late_total}; accepted IDs={late_accepted}')
    print(f'E2E stored_ts-sent_ts: n={len(latencies)}, p50={row["p50_ms"]} ms, p95={row["p95_ms"]} ms, p99={row["p99_ms"]} ms, max={row["max_ms"]} ms')
    settings=call(args.es+f'/{args.index}/_settings')[args.index]['settings']['index']
    print(f'Elasticsearch refresh_interval={settings.get("refresh_interval","default")}')
    print('Saved report row to ket-qua/tong-hop-pipeline.csv')
    if saved_total+len(failed)+len(skipped)<expected: print('WARNING: sender outcomes do not cover the full measured offered window; inspect per-run LoadGen output.')
if __name__=='__main__': main()
