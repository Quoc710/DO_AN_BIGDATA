# Viec 4: do toc do truy van tren PostgreSQL (de so voi Elasticsearch cua he thong B).
#  1. Nap dataset apache_500k vao bang log_q, nhan ban -Copies lan (mac dinh 10 lan = 5 trieu dong)
#  2. Chay 5 cau truy van khi CHUA co chi muc, moi cau -Reps lan
#  3. Tao chi muc (pg_trgm cho message, level+ts, ts+service) roi chay lai 5 cau
# Cach chay (PowerShell, thu muc DO_AN_BIGDATA, PostgreSQL dang bat):
#   powershell -ExecutionPolicy Bypass -File .\chay-truy-van.ps1
# Mat khoang 15-30 phut. Cam sac, che do Best performance, tat app nang.
# Khong dung toi bang app_log (ket qua do ghi van con nguyen).

param(
    [int]$Copies = 10,
    [int]$Reps = 10
)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host ""; Write-Host "LOI: $msg" -ForegroundColor Red; exit 1 }

$running = docker ps --format "{{.Names}}" | Select-String -SimpleMatch "la-postgres"
if (-not $running) { Fail "Container la-postgres chua chay. Chay chay-baseline.ps1 truoc." }
if (-not (Test-Path "loadgen/apache_500k.jsonl.gz")) { Fail "Khong thay loadgen/apache_500k.jsonl.gz" }
$out = Join-Path $PSScriptRoot "ket-qua"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$psql = @("exec", "la-postgres", "psql", "-U", "loguser", "-d", "logdb", "-q")

Step "0/4 Chep dataset va file SQL vao container"
docker cp loadgen/apache_500k.jsonl.gz la-postgres:/apache_500k.jsonl.gz | Out-Null
foreach ($f in "q-nap.sql", "q-index.sql", "q-do.sql") { docker cp $f "la-postgres:/$f" | Out-Null }

Step "1/4 Nap $Copies x 500.000 dong vao bang log_q (vai phut)"
$t = Get-Date
docker @psql -v copies=$Copies -f /q-nap.sql
if ($LASTEXITCODE -ne 0) { Fail "Nap du lieu khong duoc." }
Write-Host ("Nap xong sau {0:N0} giay" -f ((Get-Date) - $t).TotalSeconds)
docker exec la-postgres psql -U loguser -d logdb -c "DROP TABLE IF EXISTS q_ketqua" | Out-Null

Step "2/4 Do 5 cau truy van khi CHUA co chi muc ($Reps lan moi cau)"
docker @psql -v nhan=khong-index -v reps=$Reps -f /q-do.sql
if ($LASTEXITCODE -ne 0) { Fail "Chay truy van khong duoc." }

Step "3/4 Tao chi muc (vai phut)"
$t = Get-Date
docker @psql -f /q-index.sql
if ($LASTEXITCODE -ne 0) { Fail "Tao chi muc khong duoc." }
Write-Host ("Tao chi muc xong sau {0:N0} giay" -f ((Get-Date) - $t).TotalSeconds)

Step "4/4 Do lai 5 cau truy van khi CO chi muc"
docker @psql -v nhan=co-index -v reps=$Reps -f /q-do.sql
if ($LASTEXITCODE -ne 0) { Fail "Chay truy van khong duoc." }

$sum = "SELECT nhan, cau, count(*) AS so_lan, round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS trung_vi_ms, round(min(ms), 2) AS min_ms, round(max(ms), 2) AS max_ms, max(ket_qua) AS ket_qua FROM q_ketqua GROUP BY nhan, cau ORDER BY nhan DESC, cau"
docker exec la-postgres psql -U loguser -d logdb --csv -c $sum | Out-File -Encoding ascii (Join-Path $out "truy-van.csv")
docker exec la-postgres psql -U loguser -d logdb --csv -c "SELECT * FROM q_ketqua ORDER BY nhan DESC, cau, lan" | Out-File -Encoding ascii (Join-Path $out "truy-van-tung-lan.csv")
docker exec la-postgres psql -U loguser -d logdb -c "SELECT count(*) AS so_dong, pg_size_pretty(pg_table_size('log_q')) AS bang, pg_size_pretty(pg_indexes_size('log_q')) AS chi_muc FROM log_q" |
    Tee-Object -FilePath (Join-Path $out "truy-van-kich-thuoc.txt")
Import-Csv (Join-Path $out "truy-van.csv") | Format-Table -AutoSize
Write-Host "XONG. Gui file ket-qua\truy-van.csv va ket-qua\truy-van-kich-thuoc.txt cho Claude." -ForegroundColor Green
Write-Host "Muon xoa bang thu nghiem cho nhe may: docker exec la-postgres psql -U loguser -d logdb -c `"DROP TABLE log_q, q_ketqua`""
