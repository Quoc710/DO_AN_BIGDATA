# Viec 1: do baseline GHI THEO LO (group commit).
# Script nay: build lai app (co them /logs-batch), roi chay 6 muc tai x 5 lan.
# Cach chay (PowerShell, dung o thu muc DO_AN_BIGDATA, Docker Desktop dang bat):
#   powershell -ExecutionPolicy Bypass -File .\chay-ghi-theo-lo.ps1
# Mat khoang 70 phut. Khong can ngoi canh, nhung dung mo app nang trong luc chay.

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host ""; Write-Host "LOI: $msg" -ForegroundColor Red; Write-Host "Chup man hinh doan nay gui lai nhe."; exit 1 }

Step "1/3 Build lai app (them duong dan /logs-batch)"
docker compose up -d postgres
docker compose --profile app up -d --build
if ($LASTEXITCODE -ne 0) { Fail "Build app khong duoc. Xem dong loi o tren." }

Step "2/3 Doi app san sang"
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 http://localhost:8080/batch-stats
        if ($r.StatusCode -eq 200) { $ok = $true; Write-Host "App tra loi: $($r.Content)"; break }
    } catch { }
    Start-Sleep -Seconds 3
}
if (-not $ok) {
    docker logs --tail 40 la-app
    Fail "App khong co /batch-stats sau 3 phut. Log cua app o tren."
}

Step "3/3 Do ghi theo lo: 1000, 2000, 3000, 3500, 4000, 5000 log/s, moi muc 5 lan"
& powershell -ExecutionPolicy Bypass -File .\chay-tat-ca.ps1 -Mode batch -Rates "1000,2000,3000,3500,4000,5000" -Repeats 5 -SkipNoop

Write-Host ""
Write-Host "Ket qua: ket-qua\tong-hop.csv (cac dong pgb-...) va ket-qua\batch-size.csv. Gui 2 file nay cho Claude." -ForegroundColor Green
