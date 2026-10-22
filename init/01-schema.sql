-- Bảng log cho baseline (Spring Boot -> PostgreSQL).
-- PostgreSQL tự chạy file này ở lần khởi động ĐẦU TIÊN (khi volume pgdata còn trống).
CREATE TABLE IF NOT EXISTS app_log (
  run_id     VARCHAR(40)  NOT NULL,              -- nhãn lần chạy, vd pg-1000
  log_id     BIGINT       NOT NULL,              -- số thứ tự trong lần chạy, đếm từ 1
  service_id VARCHAR(40)  NOT NULL,
  level      VARCHAR(10)  NOT NULL,
  message    VARCHAR(255) NOT NULL,
  sent_ts    BIGINT       NOT NULL,              -- epoch ms, bộ bắn tải gán lúc gửi
  stored_ts  TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),  -- PostgreSQL tự điền lúc ghi
  PRIMARY KEY (run_id, log_id)
);
