-- Viec 4: tao chi muc cho tung kieu truy van (giong cach Elasticsearch danh chi muc san).
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS log_q_msg_trgm ON log_q USING gin (message gin_trgm_ops);  -- tim chu trong message
CREATE INDEX IF NOT EXISTS log_q_level_ts ON log_q (level, ts);                       -- loc theo level, sap theo gio
CREATE INDEX IF NOT EXISTS log_q_ts_svc  ON log_q (ts, service_id);                   -- khoang thoi gian + service
ANALYZE log_q;
SELECT indexrelname AS chi_muc, pg_size_pretty(pg_relation_size(indexrelid)) AS kich_thuoc
FROM pg_stat_user_indexes WHERE relname = 'log_q' ORDER BY 1;
