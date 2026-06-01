@echo off
setlocal enabledelayedexpansion
set "CONFIG=%USERPROFILE%\.dagtech-miner\config.env"
set "CPU_BIN=%USERPROFILE%\.dagtech-miner\bin\dagtech-miner.exe"
set "GPU_BIN=%USERPROFILE%\.dagtech-miner\bin\dagtech-gpu-miner.exe"
set "DASHBOARD=%USERPROFILE%\.dagtech-miner\dashboard"
set "LOG_DIR=%USERPROFILE%\.dagtech-miner\logs"

REM Read config (skip comment lines starting with #)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONFIG%") do (
    set "%%a=%%b"
)

if not defined MINING_MODE set "MINING_MODE=cpu"
if not defined METRICS_PORT set "METRICS_PORT=8880"

echo.
echo   DagTech Miner - dagtech.network
echo   Pool: !POOL_HOST!:!POOL_PORT!
echo   Wallet: !WALLET!
echo   Mode: !MINING_MODE!
if "!MINING_MODE!" NEQ "gpu" echo   Threads: !THREADS!
echo.

REM Start dashboard
if exist "%DASHBOARD%\dashboard_server.py" (
    start /min python "%DASHBOARD%\dashboard_server.py" 8881 !METRICS_PORT! 2>nul
    echo [DagTech] Dashboard: http://localhost:8881
) else if exist "%DASHBOARD%\index.html" (
    start /min python -m http.server 8881 --bind 127.0.0.1 --directory "%DASHBOARD%" 2>nul
    echo [DagTech] Dashboard: http://localhost:8881 ^(static mode^)
)

REM GPU-only mode
if "!MINING_MODE!"=="gpu" (
    if not exist "!GPU_BIN!" (
        echo [DagTech] ERROR: GPU miner not found: !GPU_BIN!
        echo [DagTech] Re-run the installer with CUDA support.
        pause
        exit /b 1
    )
    echo [DagTech] Starting GPU miner...
    "!GPU_BIN!" --wallet !WALLET! --host !POOL_HOST! --port !POOL_PORT! --worker !WORKER_NAME!-gpu
    goto :eof
)

REM CPU+GPU mode
if "!MINING_MODE!"=="both" (
    if exist "!GPU_BIN!" (
        echo [DagTech] Starting GPU miner ^(background^)...
        start /min "DagTech GPU Miner" "!GPU_BIN!" --wallet !WALLET! --host !POOL_HOST! --port !POOL_PORT! --worker !WORKER_NAME!-gpu
    ) else (
        echo [DagTech] GPU miner not found, running CPU only
    )
    echo [DagTech] Starting CPU miner...
    "!CPU_BIN!" --wallet !WALLET! --pool !POOL_HOST! --port !POOL_PORT! --threads !THREADS! --worker !WORKER_NAME! --metrics-port !METRICS_PORT!
    goto :eof
)

REM CPU-only mode (default)
echo [DagTech] Starting CPU miner...
"!CPU_BIN!" --wallet !WALLET! --pool !POOL_HOST! --port !POOL_PORT! --threads !THREADS! --worker !WORKER_NAME! --metrics-port !METRICS_PORT!
