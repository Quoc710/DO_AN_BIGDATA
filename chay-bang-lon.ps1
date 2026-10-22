# Viec 3: chay dai tren bang lon.
#  1. Xoa bang, nap san 10 trieu dong (giong bang log da chay lau ngay)
#  2. Ban 2500 log/s lien tuc 30 phut (duoi diem gay)
#  3. Tinh so do theo tung phut de xem bang to dan co lam cham he thong khong
# Cach chay (PowerShell, thu muc DO_AN_BIGDATA, PostgreSQL va app dang bat):
#   powershell -ExecutionPolicy Bypass -File .\chay-bang-lon.ps1
#   Ban ghi theo lo: them -Mode batch
#   Lan doi chung bang trong: them -Preload 0
# Mat khoang 40 phut. Dung mo app nang trong luc chay.

param(
    [int]$Rate = 2500,
    [int]$Minutes = 30,
    [long]$Preload = 10000000,
    [ValidateSet("single", "batch")][string]$Mode = "single"
)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host ""; Write-Host "LOI: $msg" -ForegroundColor Red; exit 1 }

try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 http://localhost:8080/clock | Out-Null }
catch { Fail "App chua chay. Chay chay-baseline.ps1 truoc." }

if ($Mode -eq "batch") { $Path = "/logs-batch"; $run = "pgb-long-$Rate" } else { $Path = "/logs"; $run = "pg-long-$Rate" }
if ($Preload -eq 0) { $run += "-trong" }
$out = Join-Path $PSScriptRoot "ket-qua"
New-Item -ItemType Directory -Force -Path $out | Out-Null

Step "1/3 Xoa bang va nap san $Preload dong (vai phut)"
docker cp nap-bang-lon.sql la-postgres:/nap-bang-lon.sql | Out-Null
docker cp metrics-theo-phut.sql la-postgres:/metrics-theo-phut.sql | Out-Null
docker exec la-postgres psql -U loguser -d logdb -c "TRUNCATE app_log" | Out-Null
if ($Preload -gt 0) {
    docker exec la-postgres psql -U loguser -d logdb -v n=$Preload -f /nap-bang-lon.sql
    if ($LASTEXITCODE -ne 0) { Fail "Nap du lieu khong duoc." }
    Write-Host "Cho 60 giay cho PostgreSQL ghi xong du lieu nap xuong dia..."
    docker exec la-postgres psql -U loguser -d logdb -c "CHECKPOINT" | Out-Null
    Start-Sleep -Seconds 60
} else { Write-Host "Preload = 0: chay tren bang trong (lan doi chung)" }

Step "2/3 Ban $Rate log/s trong $Minutes phut ($Path), ghi CPU/IO moi 5 giay"
$dur = $Minutes * 60
$mon = Join-Path $out "$run-theo-doi.csv"
"giay,pg_cpu_pct,app_cpu_pct,pg_mem,pg_block_io,autovacuum_dang_chay,so_checkpoint" | Out-File -Encoding ascii $mon
$logFile = Join-Path $out "$run-loadgen.txt"
$p = Start-Process -FilePath "java" -NoNewWindow -PassThru -RedirectStandardOutput $logFile `
     -ArgumentList @("loadgen/LoadGen.java", "--file", "loadgen/apache_500k.jsonl.gz", "--rate", "$Rate", "--duration", "$dur", "--run-id", $run, "--path", $Path)
$start = Get-Date
$sql = "SELECT (SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker') || ',' || (SELECT checkpoints_timed + checkpoints_req FROM pg_stat_bgwriter)"
while (-not $p.HasExited) {
    $t = [int]((Get-Date) - $start).TotalSeconds
    $pg = ""; $app = ""; $mem = ""; $io = ""
    foreach ($l in (docker stats --no-stream --format "{{.Name}};{{.CPUPerc}};{{.MemUsage}};{{.BlockIO}}" la-postgres la-app)) {
        $f = "$l".Split(";")
        if ($f.Count -lt 4) { continue }
        if ($f[0] -eq "la-postgres") { $pg = $f[1].TrimEnd("%"); $mem = $f[2].Split("/")[0].Trim(); $io = $f[3].Replace(" ", "") }
        elseif ($f[0] -eq "la-app") { $app = $f[1].TrimEnd("%") }
    }
    $db = "$(docker exec la-postgres psql -U loguser -d logdb -tAc $sql)".Trim()
    "$t,$pg,$app,$mem,$io,$db" | Out-File -Encoding ascii -Append $mon
    if ($t % 60 -lt 6) { Write-Host ("  {0,5}s  CPU pg {1}%  CPU app {2}%  RAM pg {3}  IO pg {4}  autovacuum,checkpoint {5}" -f $t, $pg, $app, $mem, $io, $db) }
    Start-Sleep -Seconds 5
}
Get-Content $logFile | Select-Object -Last 8

Step "3/3 So do theo tung phut"
$csv = Join-Path $out "$run-theo-phut.csv"
"phut,can_nhan,da_luu,ti_le_mat_pct,throughput_log_per_s,p50_ms,p95_ms,p99_ms" | Out-File -Encoding ascii $csv
docker exec la-postgres psql -U loguser -d logdb -tA -v run=$run -v rate=$Rate -f /metrics-theo-phut.sql |
    Where-Object { $_.Trim() -ne "" } | Out-File -Encoding ascii -Append $csv
docker exec la-postgres psql -U loguser -d logdb -c "SELECT count(*) AS tong_dong, pg_size_pretty(pg_total_relation_size('app_log')) AS dung_luong FROM app_log" |
    Tee-Object -FilePath (Join-Path $out "$run-kich-thuoc.txt")
Import-Csv $csv | Format-Table -AutoSize
Write-Host "XONG. Gui file ket-qua\$run-theo-phut.csv va ket-qua\$run-theo-doi.csv cho Claude." -ForegroundColor Green
