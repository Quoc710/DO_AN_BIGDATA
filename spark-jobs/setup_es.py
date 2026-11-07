import json, urllib.request, urllib.error

ES='http://localhost:9200'
def call(path,method='GET',body=None):
    data=None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(ES+path,data=data,headers={} if data is None else {'Content-Type':'application/json'},method=method)
    try:
        with urllib.request.urlopen(req,timeout=30) as r:
            raw=r.read(); return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code==404: return None
        raise

call('/_ingest/pipeline/logs-ingest-time','PUT',{'description':'Stamp the time Elasticsearch receives each log','processors':[{'set':{'field':'stored_ts','value':'{{_ingest.timestamp}}','override':True}}]})
call('/_index_template/logs-benchmark-template','PUT',{
 'index_patterns':['app-logs-*'],'priority':500,
 'template':{'settings':{'number_of_shards':1,'number_of_replicas':0,'refresh_interval':'1s','default_pipeline':'logs-ingest-time'},
  'mappings':{'properties':{'run_id':{'type':'keyword'},'log_id':{'type':'long'},'service_id':{'type':'keyword'},
   'level':{'type':'keyword'},'message':{'type':'text'},'sent_ts':{'type':'date','format':'epoch_millis'},'stored_ts':{'type':'date'}}}}
})
print('Ready: ingest pipeline logs-ingest-time and one-index-per-run template (1 shard, 0 replicas, refresh 1s).')
