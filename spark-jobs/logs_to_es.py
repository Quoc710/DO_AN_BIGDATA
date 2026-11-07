import json, urllib.request, urllib.error
from pyspark.sql import SparkSession, functions as F, types as T

KAFKA = 'kafka:29092'
TOPIC = 'logs'
ES = 'http://elasticsearch:9200'
INDEX_PREFIX = 'app-logs-'

schema = T.StructType([
    T.StructField('run_id', T.StringType()), T.StructField('log_id', T.LongType()),
    T.StructField('service_id', T.StringType()), T.StructField('level', T.StringType()),
    T.StructField('message', T.StringType()), T.StructField('sent_ts', T.LongType())
])

def write_partition(rows):
    # Spark executors run this on worker containers. Stable Elasticsearch _id makes batch retries idempotent.
    # Import inside the executor function: Python worker processes do not inherit the driver's
    # imported urllib submodules, even though this function is serialized to those workers.
    import urllib.request

    batch = []
    def flush():
        if not batch: return
        body = ''.join(json.dumps({'index': {'_index': x[2], '_id': x[0]}}) + '\n' + json.dumps(x[1], ensure_ascii=False) + '\n' for x in batch).encode()
        req = urllib.request.Request(ES + '/_bulk', data=body, headers={'Content-Type': 'application/x-ndjson'}, method='POST')
        with urllib.request.urlopen(req, timeout=60) as response:
            result = json.loads(response.read())
        errors = [i for i in result.get('items', []) if i.get('index', {}).get('status', 500) >= 300]
        if errors: raise RuntimeError('Elasticsearch bulk errors: ' + str(errors[:3]))
        batch.clear()
    for row in rows:
        d = row.asDict(recursive=True)
        if d.get('run_id') is None or d.get('log_id') is None: continue
        doc_id = str(d['run_id']) + ':' + str(d['log_id'])
        batch.append((doc_id, d, INDEX_PREFIX + d['run_id'].lower()))
        if len(batch) >= 500: flush()
    flush()

spark = SparkSession.builder.appName('logs-kafka-to-elasticsearch').getOrCreate()
raw = (spark.readStream.format('kafka').option('kafka.bootstrap.servers', KAFKA)
       .option('subscribe', TOPIC).option('startingOffsets', 'latest')
       .option('failOnDataLoss', 'false').load())
parsed = raw.select(F.from_json(F.col('value').cast('string'), schema).alias('e')).select('e.*')
valid = parsed.filter(F.col('run_id').isNotNull() & F.col('log_id').isNotNull())
query = (valid.writeStream.outputMode('append').foreachBatch(lambda df, epoch: df.repartition(2).foreachPartition(write_partition))
         .option('checkpointLocation', '/tmp/spark-checkpoints/logs-to-es-cluster').trigger(processingTime='1 second').start())
query.awaitTermination()
