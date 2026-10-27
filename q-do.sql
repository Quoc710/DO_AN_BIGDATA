-- Viec 4: chay 5 cau truy van, moi cau 2 lan khoi dong (khong tinh) + :reps lan do.
-- Thoi gian do ngay trong PostgreSQL (clock_timestamp), khong tinh thoi gian mang/psql.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS q_ketqua (nhan text, cau text, lan int, ms numeric, ket_qua bigint);
DELETE FROM q_ketqua WHERE nhan = :'nhan';
SELECT set_config('q.nhan', :'nhan', false), set_config('q.reps', :'reps', false) \g /dev/null
DO $$
DECLARE
  qs text[][] := ARRAY[
    ['Q1 tim chu forbidden',        'SELECT count(*) FROM log_q WHERE message ILIKE ''%forbidden%'''],
    ['Q2 tim cum error state',      'SELECT count(*) FROM log_q WHERE message ILIKE ''%error state%'''],
    ['Q3 dem theo level',           'SELECT level, count(*) FROM log_q GROUP BY level'],
    ['Q4 dem theo service 1 ngay',  'SELECT service_id, count(*) FROM log_q WHERE ts >= ''2026-01-10'' AND ts < ''2026-01-11'' GROUP BY service_id'],
    ['Q5 100 log error moi nhat',   'SELECT * FROM log_q WHERE level = ''error'' ORDER BY ts DESC LIMIT 100']
  ];
  i int; k int; t0 timestamptz; n bigint;
  reps int := current_setting('q.reps')::int;
  nhan text := current_setting('q.nhan');
BEGIN
  FOR i IN 1 .. array_length(qs, 1) LOOP
    IF i <= 2 THEN EXECUTE qs[i][2] INTO n;                                   -- so log tim thay
    ELSE EXECUTE 'SELECT count(*) FROM (' || qs[i][2] || ') x' INTO n;       -- so dong ket qua
    END IF;
    FOR k IN 1 .. 2 LOOP EXECUTE qs[i][2]; END LOOP;                          -- khoi dong
    FOR k IN 1 .. reps LOOP
      t0 := clock_timestamp();
      EXECUTE qs[i][2];
      INSERT INTO q_ketqua VALUES (nhan, qs[i][1], k, extract(epoch FROM clock_timestamp() - t0) * 1000, n);
    END LOOP;
  END LOOP;
END $$;
SELECT nhan, cau, count(*) AS so_lan,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS trung_vi_ms,
       round(min(ms), 2) AS min_ms, round(max(ms), 2) AS max_ms, max(ket_qua) AS ket_qua
FROM q_ketqua WHERE nhan = :'nhan' GROUP BY nhan, cau ORDER BY cau;
