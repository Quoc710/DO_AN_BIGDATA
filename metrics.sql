-- Tính số đo cho 1 lần chạy (lần chạy phải dài ít nhất 90 giây).
-- Chép file vào container 1 lần:   docker cp metrics.sql la-postgres:/metrics.sql
-- Mỗi lần đo (thay pg-1000 và 1000 bằng run_id và tốc độ của lần chạy đó):
--   docker exec -it la-postgres psql -U loguser -d logdb -v run=pg-1000 -v rate=1000 -f /metrics.sql
-- Cửa sổ đo: bỏ 30 giây đầu (khởi động), lấy 60 giây tiếp theo.
-- Log thứ n được hẹn gửi ở giây n/rate, nên log thuộc cửa sổ đo là log_id từ 30*rate+1 đến 90*rate.
\pset footer off

\echo '== 1. Ti le mat log trong 60 giay do =='
SELECT 60 * :rate                                                  AS can_nhan,
       count(*)                                                    AS da_luu,
       round(100 * (1 - count(*)::numeric / (60 * :rate)), 3)      AS ti_le_mat_pct
FROM app_log
WHERE run_id = :'run' AND log_id > 30 * :rate AND log_id <= 90 * :rate;

\echo '== 2. Throughput: so log luu duoc moi giay trong 60 giay do =='
WITH b AS (SELECT min(sent_ts) AS t0 FROM app_log WHERE run_id = :'run')
SELECT round(count(*) / 60.0, 1) AS throughput_log_per_s
FROM app_log, b
WHERE run_id = :'run'
  AND EXTRACT(EPOCH FROM stored_ts) * 1000 >= b.t0 + 30000
  AND EXTRACT(EPOCH FROM stored_ts) * 1000 <  b.t0 + 90000;

\echo '== 3. Do tre end-to-end (ms) cua cac log trong 60 giay do =='
WITH x AS (SELECT EXTRACT(EPOCH FROM stored_ts) * 1000 - sent_ts AS lat
           FROM app_log
           WHERE run_id = :'run' AND log_id > 30 * :rate AND log_id <= 90 * :rate)
SELECT count(*)                                                              AS so_log,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY lat)::numeric, 1)  AS p50_ms,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY lat)::numeric, 1)  AS p95_ms,
       round(percentile_cont(0.99) WITHIN GROUP (ORDER BY lat)::numeric, 1)  AS p99_ms,
       round(max(lat)::numeric, 1)                                           AS max_ms
FROM x;
