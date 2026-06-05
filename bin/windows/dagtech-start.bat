@echo off
setlocal enabledelayedexpansion
REM ============================================================================
REM DagTech Miner Launcher
REM Path-relative — works regardless of install location.
REM %~dp0 = directory of this batch file (always ends with \)
REM ============================================================================

set "BIN_DIR=%~dp0"
set "INSTALL_DIR=%~dp0.."
for %%I in ("%INSTALL_DIR%") do set "INSTALL_DIR=%%~fI"

set "CPU_BIN=%BIN_DIR%dagtech-miner.exe"
set "GPU_BIN=%BIN_DIR%dagtech-gpu-miner.exe"
set "DASHBOARD=%INSTALL_DIR%\dashboard"
set "LOG_DIR=%INSTALL_DIR%\logs"

REM Config: prefer install-dir copy; fall back to user-profile copy
set "CONFIG=%INSTALL_DIR%\config.env"
if not exist "%CONFIG%" set "CONFIG=%USERPROFILE%\.dagtech-miner\config.env"

if not exist "%CONFIG%" (
    echo [DagTech] ERROR: config.env not found.
    echo [DagTech] Looked at: %INSTALL_DIR%\config.env
    echo [DagTech] Also at:   %USERPROFILE%\.dagtech-miner\config.env
    echo [DagTech] Re-run the installer to generate a config.
    pause
    exit /b 1
)

if not exist "%CPU_BIN%" (
    echo [DagTech] ERROR: miner binary not found at %CPU_BIN%
    echo [DagTech] Install appears incomplete. Re-run the installer.
    pause
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" 2>nul

REM Read config (skip comment lines starting with #)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONFIG%") do (
    set "%%a=%%b"
)

if not defined MINING_MODE set "MINING_MODE=cpu"
if not defined METRICS_PORT set "METRICS_PORT=8880"
if not defined THREADS set "THREADS=4"
if not defined WORKER_NAME set "WORKER_NAME=dagtech"

REM Validate wallet
if not defined WALLET (
    echo [DagTech] ERROR: WALLET not set in config.env
    pause
    exit /b 2
)
echo !WALLET! | findstr /R "^0x[0-9a-fA-F][0-9a-fA-F]*$" >nul
if errorlevel 1 (
    echo [DagTech] ERROR: WALLET in config.env is not a valid 0x hex address: !WALLET!
    pause
    exit /b 2
)
REM Reject the well-known dev default — prevents silent reward redirection
if /I "!WALLET!"=="0x6387C32cCDD60BfBa00EC70A67715Dcd52E8083f" (
    echo [DagTech] ERROR: WALLET is set to the bundled default ^(developer wallet^).
    echo [DagTech] Edit %CONFIG% and set WALLET to YOUR own address.
    pause
    exit /b 2
)

echo.
echo   DagTech Miner - dagtech.network
echo   Pool: !POOL_HOST!:!POOL_PORT!
echo   Wallet: !WALLET!
echo   Mode: !MINING_MODE!
if "!MINING_MODE!" NEQ "gpu" echo   Threads: !THREADS!
echo.

REM Start dashboard server (independent of miner)
if exist "%DASHBOARD%\dashboard_server.py" (
    start /min python "%DASHBOARD%\dashboard_server.py" 8881 !METRICS_PORT! 2>nul
    echo [DagTech] Dashboard: http://localhost:8881
) else if exist "%DASHBOARD%\index.html" (
    start /min python -m http.server 8881 --bind 127.0.0.1 --directory "%DASHBOARD%" 2>nul
    echo [DagTech] Dashboard: http://localhost:8881 (static mode)
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
    "!GPU_BIN!" --wallet !WALLET! --host !POOL_HOST! --port !POOL_PORT! --worker !WORKER_NAME!-gpu 2>>"%LOG_DIR%\gpu-miner.log"
    goto :eof
)

REM CPU+GPU mode
if "!MINING_MODE!"=="both" (
    if exist "!GPU_BIN!" (
        echo [DagTech] Starting GPU miner (background)...
        start /min "DagTech GPU Miner" "!GPU_BIN!" --wallet !WALLET! --host !POOL_HOST! --port !POOL_PORT! --worker !WORKER_NAME!-gpu
    ) else (
        echo [DagTech] GPU miner not found, running CPU only
    )
    echo [DagTech] Starting CPU miner...
    "!CPU_BIN!" --wallet !WALLET! --pool !POOL_HOST! --port !POOL_PORT! --threads !THREADS! --worker !WORKER_NAME! --metrics-port !METRICS_PORT! 2>>"%LOG_DIR%\cpu-miner.log"
    goto :eof
)

REM CPU-only mode (default) — also log stderr to file so dashboard can surface crashes
echo [DagTech] Starting CPU miner...
"!CPU_BIN!" --wallet !WALLET! --pool !POOL_HOST! --port !POOL_PORT! --threads !THREADS! --worker !WORKER_NAME! --metrics-port !METRICS_PORT! 2>>"%LOG_DIR%\cpu-miner.log"
