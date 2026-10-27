-- Viec 4: nap du lieu cho phep do truy van.
-- Doc /apache_500k.jsonl.gz trong container, nhan ban :copies lan (moi lan 500.000 dong),
-- rai thoi gian ts deu tren 30 ngay (1/1 toi 31/1/2026).
\set ON_ERROR_STOP on
DROP TABLE IF EXISTS log_q;
DROP TABLE IF EXISTS raw_q;
CREATE UNLOGGED TABLE raw_q (line text);
-- Doc nguyen dong JSON (dung csv voi ky tu quote/delimiter khong bao gio xuat hien)
COPY raw_q FROM PROGRAM 'gunzip -c /apache_500k.jsonl.gz' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');
CREATE TABLE log_q (
  log_id     BIGINT       NOT NULL PRIMARY KEY,
  service_id VARCHAR(40)  NOT NULL,
  level      VARCHAR(10)  NOT NULL,
  message    VARCHAR(255) NOT NULL,
  ts         TIMESTAMPTZ  NOT NULL
);
SELECT set_config('q.n', ((SELECT count(*) FROM raw_q) * :copies)::text, false) \g /dev/null
INSERT INTO log_q
SELECT r, j->>'service_id', j->>'level', j->>'message',
       timestamptz '2026-01-01 00:00:00+00' + make_interval(secs => r::float8 * 2592000 / current_setting('q.n')::float8)
FROM (
  SELECT k * c.cnt + (s.j->>'log_id')::bigint AS r, s.j
  FROM generate_series(0, :copies - 1) k
  CROSS JOIN (SELECT count(*) AS cnt FROM raw_q) c
  CROSS JOIN (SELECT line::jsonb AS j FROM raw_q) s
) t
ORDER BY r;
DROP TABLE raw_q;
VACUUM ANALYZE log_q;
SELECT count(*) AS so_dong, pg_size_pretty(pg_table_size('log_q')) AS bang, pg_size_pretty(pg_indexes_size('log_q')) AS chi_muc FROM log_q;
