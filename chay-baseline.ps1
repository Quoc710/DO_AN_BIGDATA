# Tu dong dung baseline va chay thu 1 lan o 100 log/s.
# Cach chay (PowerShell, dung o thu muc DO_AN_BIGDATA):
#   powershell -ExecutionPolicy Bypass -File .\chay-baseline.ps1

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host ""; Write-Host "LOI: $msg" -ForegroundColor Red; Write-Host "Chup man hinh doan nay gui lai nhe."; exit 1 }

Step "1/6 Kiem tra Docker va Java"
docker info --format "{{.ServerVersion}}" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Docker chua chay. Mo Docker Desktop, doi bieu tuong chuyen xanh roi chay lai." }
$javaOk = Get-Command java -ErrorAction SilentlyContinue
if (-not $javaOk) { Fail "Khong tim thay java. Cai JDK 17 tro len." }
Write-Host "Docker va Java OK"

Step "2/6 Bat PostgreSQL"
docker compose up -d postgres
if ($LASTEXITCODE -ne 0) { Fail "docker compose up postgres khong chay duoc." }
$healthy = $false
for ($i = 0; $i -lt 30; $i++) {
    $st = docker inspect -f "{{.State.Health.Status}}" la-postgres
    if ($st -eq "healthy") { $healthy = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $healthy) { Fail "PostgreSQL bat len nhung chua san sang sau 60 giay." }
Write-Host "PostgreSQL OK"

Step "3/6 Kiem tra bang app_log"
$tbl = docker exec la-postgres psql -U loguser -d logdb -tAc "SELECT to_regclass('public.app_log')"
if ("$tbl".Trim() -ne "app_log") {
    Write-Host "Chua co bang, tao bang tu init/01-schema.sql"
    docker cp init/01-schema.sql la-postgres:/tmp/01-schema.sql
    docker exec la-postgres psql -U loguser -d logdb -f /tmp/01-schema.sql
    $tbl = docker exec la-postgres psql -U loguser -d logdb -tAc "SELECT to_regclass('public.app_log')"
    if ("$tbl".Trim() -ne "app_log") { Fail "Khong tao duoc bang app_log." }
}
Write-Host "Bang app_log OK"

Step "4/6 Build va bat app Spring Boot (lan dau mat vai phut)"
docker compose --profile app up -d --build
if ($LASTEXITCODE -ne 0) { Fail "Build hoac bat app khong duoc. Xem dong loi o tren." }
$appOk = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 http://localhost:8080/clock
        if ($r.StatusCode -eq 200) { $appOk = $true; Write-Host "App tra loi: $($r.Content)"; break }
    } catch { }
    Start-Sleep -Seconds 3
}
if (-not $appOk) {
    docker logs --tail 40 la-app
    Fail "App khong tra loi /clock sau 3 phut. Log cua app o tren."
}

Step "5/6 Chep file do vao container"
docker cp metrics.sql la-postgres:/metrics.sql
if ($LASTEXITCODE -ne 0) { Fail "Khong chep duoc metrics.sql." }
Write-Host "OK"

Step "6/6 Chay thu 100 log/s trong 90 giay"
docker exec la-postgres psql -U loguser -d logdb -c "TRUNCATE app_log"
java loadgen/LoadGen.java --file loadgen/apache_500k.jsonl.gz --rate 100 --run-id pg-100-test
if ($LASTEXITCODE -ne 0) { Fail "Bo ban tai bi loi." }
docker exec la-postgres psql -U loguser -d logdb -v run=pg-100-test -v rate=100 -f /metrics.sql

Write-Host ""
Write-Host "XONG. Chup man hinh ket qua o tren gui lai de kiem tra." -ForegroundColor Green
