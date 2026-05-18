@echo off
setlocal enabledelayedexpansion
set "CONFIG=%USERPROFILE%\.dagtech-miner\config.env"
set "BIN=%USERPROFILE%\.dagtech-miner\bin\dagtech-miner.exe"
set "DASHBOARD=%USERPROFILE%\.dagtech-miner\dashboard"

REM Read config
for /f "usebackq tokens=1,* delims==" %%a in ("%CONFIG%") do (
    if not "%%a"=="" if not "%%a:~0,1%"=="#" set "%%a=%%b"
)

echo.
echo   DagTech Miner - dagtech.network
echo   Pool: %POOL_HOST%:%POOL_PORT%
echo   Wallet: %WALLET%
echo   Threads: %THREADS%
echo.

REM Start dashboard
if exist "%DASHBOARD%\index.html" (
    start /min python -m http.server 8881 --bind 127.0.0.1 --directory "%DASHBOARD%" 2>nul
    echo [DagTech] Dashboard: http://localhost:8881
)

"%BIN%" --wallet %WALLET% --pool %POOL_HOST% --port %POOL_PORT% --threads %THREADS% --worker %WORKER_NAME% --metrics-port %METRICS_PORT%
