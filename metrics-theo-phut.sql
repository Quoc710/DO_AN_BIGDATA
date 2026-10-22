-- Moi phut cua 1 lan chay dai in 1 dong CSV: phut,can_nhan,da_luu,ti_le_mat_pct,throughput,p50,p95,p99
-- Dung: docker exec la-postgres psql -U loguser -d logdb -tA -v run=pg-long -v rate=2500 -f /metrics-theo-phut.sql
WITH x AS (
  SELECT ((log_id - 1) / (60 * :rate)) + 1 AS phut,
         EXTRACT(EPOCH FROM stored_ts) * 1000 - sent_ts AS lat
  FROM app_log WHERE run_id = :'run')
SELECT concat_ws(',', phut, 60 * :rate, count(*),
       round(100 * (1 - count(*)::numeric / (60 * :rate)), 3),
       round(count(*) / 60.0, 1),
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY lat)::numeric, 1),
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY lat)::numeric, 1),
       round(percentile_cont(0.99) WITHIN GROUP (ORDER BY lat)::numeric, 1))
FROM x GROUP BY phut ORDER BY phut;
