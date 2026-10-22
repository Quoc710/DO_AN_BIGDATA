-- Giong metrics.sql nhung in 1 dong CSV: run_id,rate,can_nhan,da_luu,ti_le_mat_pct,throughput,p50,p95,p99,max
-- docker exec la-postgres psql -U loguser -d logdb -tA -v run=pg-1000-r1 -v rate=1000 -f /metrics-csv.sql
WITH b AS (SELECT min(sent_ts) AS t0 FROM app_log WHERE run_id = :'run'),
w AS (SELECT EXTRACT(EPOCH FROM stored_ts) * 1000 - sent_ts AS lat
      FROM app_log WHERE run_id = :'run' AND log_id > 30 * :rate AND log_id <= 90 * :rate),
t AS (SELECT count(*) AS n FROM app_log, b
      WHERE run_id = :'run'
        AND EXTRACT(EPOCH FROM stored_ts) * 1000 >= b.t0 + 30000
        AND EXTRACT(EPOCH FROM stored_ts) * 1000 <  b.t0 + 90000)
SELECT concat_ws(',',
  :'run', :rate, 60 * :rate, (SELECT count(*) FROM w),
  round(100 * (1 - (SELECT count(*) FROM w)::numeric / (60 * :rate)), 3),
  round((SELECT n FROM t) / 60.0, 1),
  coalesce(round((SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY lat) FROM w)::numeric, 1)::text, ''),
  coalesce(round((SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY lat) FROM w)::numeric, 1)::text, ''),
  coalesce(round((SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY lat) FROM w)::numeric, 1)::text, ''),
  coalesce(round((SELECT max(lat) FROM w)::numeric, 1)::text, ''));
