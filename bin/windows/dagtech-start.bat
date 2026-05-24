@echo off
setlocal enabledelayedexpansion
set "CONFIG=%USERPROFILE%\.dagtech-miner\config.env"
set "BIN=%USERPROFILE%\.dagtech-miner\bin\dagtech-miner.exe"
set "DASHBOARD=%USERPROFILE%\.dagtech-miner\dashboard"

REM Read config (skip comment lines starting with #)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONFIG%") do (
    set "%%a=%%b"
)

echo.
echo   DagTech Miner - dagtech.network
echo   Pool: !POOL_HOST!:!POOL_PORT!
echo   Wallet: !WALLET!
echo   Threads: !THREADS!
echo.

REM Start dashboard (uses dashboard_server.py which proxies /api/metrics from miner)
if exist "%DASHBOARD%\dashboard_server.py" (
    start /min python "%DASHBOARD%\dashboard_server.py" 8881 !METRICS_PORT! 2>nul
    echo [DagTech] Dashboard: http://localhost:8881
) else if exist "%DASHBOARD%\index.html" (
    start /min python -m http.server 8881 --bind 127.0.0.1 --directory "%DASHBOARD%" 2>nul
    echo [DagTech] Dashboard: http://localhost:8881 ^(static mode - no live metrics^)
)

"!BIN!" --wallet !WALLET! --pool !POOL_HOST! --port !POOL_PORT! --threads !THREADS! --worker !WORKER_NAME! --metrics-port !METRICS_PORT!
