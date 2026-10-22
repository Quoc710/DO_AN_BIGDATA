# Tim cho nghen chinh xac: chay 1 lan o 4000 log/s, trong luc chay lien tuc ghi lai
#   - CPU cua container la-postgres va la-app (docker stats)
#   - so ket noi DB dang ban (pg_stat_activity)
# Cach chay (PowerShell, dung o thu muc DO_AN_BIGDATA, PostgreSQL va app dang bat):
#   powershell -ExecutionPolicy Bypass -File .\chay-docker-stats.ps1
#   Ban ghi theo lo:  powershell -ExecutionPolicy Bypass -File .\chay-docker-stats.ps1 -Mode batch -Rate 5000
# Mat khoang 2 phut.

param(
    [int]$Rate = 4000,
    [ValidateSet("single", "batch")][string]$Mode = "single"
)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

$out = Join-Path $PSScriptRoot "ket-qua"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if ($Mode -eq "batch") { $Path = "/logs-batch"; $Name = "batch-$Rate" } else { $Path = "/logs"; $Name = "$Rate" }
$run = "stats-$Name"
$csv = Join-Path $out "docker-stats-$Name.csv"
"giay,pg_cpu_pct,app_cpu_pct,db_ket_noi_dang_ban" | Out-File -Encoding ascii $csv

Write-Host "==> Xoa bang, bat dau ban $Rate log/s ($Path) trong 90 giay" -ForegroundColor Cyan
docker exec la-postgres psql -U loguser -d logdb -c "TRUNCATE app_log" | Out-Null
$logFile = Join-Path $out "$run-loadgen.txt"
$p = Start-Process -FilePath "java" -NoNewWindow -PassThru -RedirectStandardOutput $logFile `
     -ArgumentList @("loadgen/LoadGen.java", "--file", "loadgen/apache_500k.jsonl.gz", "--rate", "$Rate", "--run-id", $run, "--path", $Path)

$start = Get-Date
$sql = "SELECT count(*) FROM pg_stat_activity WHERE datname='logdb' AND state='active' AND pid <> pg_backend_pid()"
while (-not $p.HasExited) {
    $t = [int]((Get-Date) - $start).TotalSeconds
    $pg = 0.0; $app = 0.0
    $lines = docker stats --no-stream --format "{{.Name}},{{.CPUPerc}}" la-postgres la-app
    foreach ($l in $lines) {
        $parts = "$l".Split(",")
        if ($parts.Count -lt 2) { continue }
        $v = [double]($parts[1].Trim().TrimEnd("%"))
        if ($parts[0] -eq "la-postgres") { $pg = $v } elseif ($parts[0] -eq "la-app") { $app = $v }
    }
    $conn = docker exec la-postgres psql -U loguser -d logdb -tAc $sql
    $conn = "$conn".Trim()
    "$t,$pg,$app,$conn" | Out-File -Encoding ascii -Append $csv
    Write-Host ("  {0,3}s   CPU postgres {1,6:N1}%   CPU app {2,6:N1}%   ket noi DB dang ban {3}" -f $t, $pg, $app, $conn)
    Start-Sleep -Seconds 1
}

# Chi lay cac mau trong 60 giay do (giay 30 den 90)
$rows = Import-Csv $csv | Where-Object { [int]$_.giay -ge 30 -and [int]$_.giay -le 90 }
if ($rows.Count -eq 0) { Write-Host "Khong co mau nao trong 60 giay do." -ForegroundColor Red; exit 1 }
$pgAvg   = ($rows | ForEach-Object { [double]$_.pg_cpu_pct }  | Measure-Object -Average).Average
$appAvg  = ($rows | ForEach-Object { [double]$_.app_cpu_pct } | Measure-Object -Average).Average
$connAvg = ($rows | ForEach-Object { [double]$_.db_ket_noi_dang_ban } | Measure-Object -Average).Average

if ($pgAvg -ge 85) {
    $verdict = "PostgreSQL dung gan het 1 CPU duoc cap -> nghen do PostgreSQL thieu CPU."
} elseif ($appAvg -ge 130) {
    $verdict = "App dung gan het 1,5 CPU duoc cap -> nghen do app Spring Boot thieu CPU."
} elseif ($Mode -eq "batch") {
    $verdict = "Ca PostgreSQL va app deu con du CPU -> nghen khong nam o DB, nhieu kha nang o may ban tai / mang Docker (tran /noop khoang 5.500 log/s)."
} else {
    $verdict = "Ca PostgreSQL va app deu con du CPU -> nghen do pool 10 ket noi cua HikariCP (moi lan ghi phai cho co ket noi ranh)."
}

$summary = @(
    "Tai dat: $Rate log/s ($Path), so mau trong 60 giay do: $($rows.Count)",
    ("CPU postgres trung binh: {0:N1}% (gioi han 100%)" -f $pgAvg),
    ("CPU app trung binh:      {0:N1}% (gioi han 150%)" -f $appAvg),
    ("Ket noi DB dang ban trung binh: {0:N1} / 10" -f $connAvg),
    "KET LUAN: $verdict"
)
$summary | Out-File -Encoding ascii (Join-Path $out "docker-stats-$Name-ketluan.txt")
Write-Host ""
$summary | ForEach-Object { Write-Host $_ -ForegroundColor Green }
Write-Host "Da luu: ket-qua\docker-stats-$Name.csv va ket-qua\docker-stats-$Name-ketluan.txt"
