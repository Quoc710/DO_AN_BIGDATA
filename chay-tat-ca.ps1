# Chay du bo do baseline: kiem tra may ban tai, roi 3 muc tai x 3 lan.
# Can chay chay-baseline.ps1 thanh cong truoc (PostgreSQL va app dang bat).
# Cach chay (PowerShell, dung o thu muc DO_AN_BIGDATA):
#   powershell -ExecutionPolicy Bypass -File .\chay-tat-ca.ps1
# Tuy chon:
#   -Rates "2000,3000,4000,5000"   cac muc tai (mac dinh "100,1000,10000")
#   -Repeats 3                     so lan moi muc
#   -Workers 400                   so luong gui song song cua bo ban tai
#   -SkipNoop                      bo qua buoc kiem tra may ban tai
#   -Mode single|batch             single = ghi tung dong (/logs), batch = ghi theo lo (/logs-batch)
#   -Tag "v2"                      them duoi vao run_id de khong trung voi lan chay cu
# Tong thoi gian khoang 25 phut. Trong luc chay dung mo app nang (game, Chrome nhieu tab...).

param(
    [string]$Rates = "100,1000,10000",
    [int]$Repeats = 3,
    [int]$Workers = 400,
    [switch]$SkipNoop,
    [ValidateSet("single", "batch")][string]$Mode = "single",
    [string]$Tag = ""
)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

$RateList = $Rates.Split(",") | ForEach-Object { [int]$_.Trim() }
$Rest    = 30      # nghi giua 2 lan chay (giay)
if ($Mode -eq "batch") { $Path = "/logs-batch"; $Prefix = "pgb" } else { $Path = "/logs"; $Prefix = "pg" }
$Suffix = ""
if ($Workers -ne 400) { $Suffix += "-w$Workers" }
if ($Tag -ne "") { $Suffix += "-$Tag" }

function BatchStats() {
    try {
        $j = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 http://localhost:8080/batch-stats | ConvertFrom-Json
        return @([long]$j.batches, [long]$j.rows)
    } catch { return $null }
}

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host ""; Write-Host "LOI: $msg" -ForegroundColor Red; exit 1 }

Step "Kiem tra app va DB dang chay"
try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 http://localhost:8080/clock
} catch { Fail "App chua chay. Chay chay-baseline.ps1 truoc." }
docker cp metrics.sql la-postgres:/metrics.sql | Out-Null
docker cp metrics-csv.sql la-postgres:/metrics-csv.sql | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Khong chep duoc file do vao container." }
if ($Mode -eq "batch" -and $null -eq (BatchStats)) {
    Fail "App chua co ban ghi theo lo. Chay: docker compose --profile app up -d --build"
}

$out = Join-Path $PSScriptRoot "ket-qua"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$summary = Join-Path $out "tong-hop.csv"
if (-not (Test-Path $summary)) {
    "run_id,rate,can_nhan,da_luu,ti_le_mat_pct,throughput_log_per_s,p50_ms,p95_ms,p99_ms,max_ms" | Out-File -Encoding ascii $summary
}

if (-not $SkipNoop) {
    Step "Kiem tra may ban tai o 10000 log/s (khong ghi DB, 30 giay)"
    java loadgen/LoadGen.java --file loadgen/apache_500k.jsonl.gz --rate 10000 --duration 30 --run-id noop-10000-w$Workers --path /noop --workers $Workers |
        Tee-Object -FilePath (Join-Path $out "noop-10000-w$Workers.txt")
    Start-Sleep -Seconds $Rest
}

foreach ($rate in $RateList) {
    for ($k = 1; $k -le $Repeats; $k++) {
        $run = "$Prefix-$rate$Suffix-r$k"
        Step "Lan chay $run"
        docker exec la-postgres psql -U loguser -d logdb -c "TRUNCATE app_log" | Out-Null
        $before = BatchStats
        java loadgen/LoadGen.java --file loadgen/apache_500k.jsonl.gz --rate $rate --run-id $run --workers $Workers --path $Path |
            Tee-Object -FilePath (Join-Path $out "$run-loadgen.txt")
        $m = docker exec la-postgres psql -U loguser -d logdb -v run=$run -v rate=$rate -f /metrics.sql
        $m | Out-File -Encoding ascii (Join-Path $out "$run-metrics.txt")
        $m | ForEach-Object { Write-Host $_ }
        $line = docker exec la-postgres psql -U loguser -d logdb -tA -v run=$run -v rate=$rate -f /metrics-csv.sql
        ("$line".Trim()) | Out-File -Encoding ascii -Append $summary
        if ($Mode -eq "batch") {
            $after = BatchStats
            $bs = Join-Path $out "batch-size.csv"
            if (-not (Test-Path $bs)) { "run_id,so_lo,so_dong,dong_moi_lo" | Out-File -Encoding ascii $bs }
            if ($null -ne $before -and $null -ne $after -and ($after[0] - $before[0]) -gt 0) {
                $nb = $after[0] - $before[0]; $nr = $after[1] - $before[1]
                $avgB = [math]::Round($nr / $nb, 1)
                "$run,$nb,$nr,$avgB" | Out-File -Encoding ascii -Append $bs
                Write-Host "Kich thuoc lo trung binh: $avgB dong/lo" -ForegroundColor Yellow
            }
        }
        Start-Sleep -Seconds $Rest
    }
}

Step "XONG. Bang tong hop:"
Import-Csv $summary | Format-Table -AutoSize
Write-Host "Tat ca ket qua nam trong thu muc ket-qua. Gui file ket-qua\tong-hop.csv va results.csv cho nhom." -ForegroundColor Green
