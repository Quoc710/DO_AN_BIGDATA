# Baseline: Spring Boot -> PostgreSQL

Giải nén bộ này vào thư mục repo DO_AN_BIGDATA, cạnh file docker-compose.

```
DO_AN_BIGDATA/
  docker-compose.yml        (bản sao của docker-compose_new.yml)
  init/01-schema.sql        bảng app_log
  app/                      Spring Boot baseline (POST /logs, POST /noop, GET /clock)
  loadgen/LoadGen.java      bộ bắn tải, chạy thẳng bằng java, không cần build
  loadgen/apache_500k.jsonl.gz (dataset nén, LoadGen đọc thẳng)
  metrics.sql               tính tỉ lệ mất log, throughput, p50/p95/p99
```

## Lệnh (PowerShell, đứng ở thư mục repo)

```powershell
cd $HOME\DO_AN_BIGDATA                           # docker-compose.yml đã có sẵn
docker compose up -d                              # bật PostgreSQL
docker exec -it la-postgres psql -U loguser -d logdb -c "\d app_log"
docker compose --profile app up -d --build        # bật app (lần đầu mất vài phút)
curl.exe http://localhost:8080/clock              # phải ra {"db_ms":...}
docker cp metrics.sql la-postgres:/metrics.sql    # chép file đo vào container, 1 lần

cd loadgen
# kiểm tra máy bắn tải (không ghi DB)
java LoadGen.java --file apache_500k.jsonl.gz --rate 10000 --duration 30 --run-id noop-10000 --path /noop
# 1 lần đo thật (90 giây = 30 giây khởi động + 60 giây đo)
docker exec -it la-postgres psql -U loguser -d logdb -c "TRUNCATE app_log"
java LoadGen.java --file apache_500k.jsonl.gz --rate 1000 --run-id pg-1000-r1
docker exec -it la-postgres psql -U loguser -d logdb -v run=pg-1000-r1 -v rate=1000 -f /metrics.sql
```

Mỗi lần chạy dùng một run_id mới. Đo xong rồi mới TRUNCATE trước lần chạy tiếp theo.
