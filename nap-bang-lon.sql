-- Nap san du lieu vao app_log de bang co kich thuoc giong he thong chay lau ngay.
-- Dung: docker exec -i la-postgres psql -U loguser -d logdb -v n=10000000 -f /nap-bang-lon.sql
-- Noi dung lay xoay vong tu 6 mau log that cua dataset Apache (giu dung do dai va phan bo level).
\timing on
INSERT INTO app_log (run_id, log_id, service_id, level, message, sent_ts, stored_ts)
SELECT 'preload', g,
       (ARRAY['svc-apache-jk2-scoreboard-assign','svc-apache-workerenv-init','svc-apache-modjk-error-state',
              'svc-apache-dir-index-forbidden','svc-apache-jk2-child-not-found','svc-apache-modjk-child-init'])[1 + (g % 6)],
       (ARRAY['notice','notice','error','error','error','error'])[1 + (g % 6)],
       (ARRAY['jk2_init() Found child ' || (6000 + g % 900) || ' in scoreboard slot ' || (g % 12),
              'workerEnv.init() ok /etc/httpd/conf/workers2.properties',
              'mod_jk child workerEnv in error state ' || (6 + g % 3),
              '[client 10.0.' || (g % 250) || '.' || (g % 200) || '] Directory index forbidden by rule: /var/www/html/',
              'jk2_init() Can''t find child ' || (6000 + g % 900) || ' in scoreboard',
              'mod_jk child init 1 -2'])[1 + (g % 6)],
       1700000000000 + g, now() - interval '1 day'
FROM generate_series(1, :n) AS g;
VACUUM ANALYZE app_log;
SELECT count(*) AS so_dong, pg_size_pretty(pg_total_relation_size('app_log')) AS dung_luong_bang FROM app_log;
