@echo off
REM ============================================================================
REM DagTech Miner - Windows Installer
REM Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
REM https://dagtech.network
REM ============================================================================
setlocal enabledelayedexpansion

set "DAGTECH_VERSION=2.1.0"
set "INSTALL_DIR=%USERPROFILE%\.dagtech-miner"
set "CONFIG_FILE=%INSTALL_DIR%\config.env"
set "BIN_DIR=%INSTALL_DIR%\bin"
set "DASHBOARD_DIR=%INSTALL_DIR%\dashboard"
set "LOG_DIR=%INSTALL_DIR%\logs"

echo.
echo   =============================================
echo     DagTech Miner v%DAGTECH_VERSION% - Windows Installer
echo     dagtech.network
echo     By Dawie Nel / DagTech Ltd
echo   =============================================
echo.

REM ---- Check Windows version ----
echo [DagTech] Checking system...
ver | findstr /i "10\. 11\." >nul 2>&1
if errorlevel 1 (
    echo [DagTech] WARNING: Recommended Windows 10 or newer
)

REM ---- Check CPU ----
echo [DagTech] Detecting hardware...
for /f "tokens=2 delims==" %%a in ('wmic cpu get NumberOfLogicalProcessors /value 2^>nul ^| find "="') do set "CPU_CORES=%%a"
for /f "tokens=2 delims==" %%a in ('wmic cpu get Name /value 2^>nul ^| find "="') do set "CPU_NAME=%%a"
for /f "tokens=2 delims==" %%a in ('wmic os get TotalVisibleMemorySize /value 2^>nul ^| find "="') do set /a "RAM_MB=%%a / 1024"

echo.
echo   Hardware Summary:
echo   CPU:     %CPU_NAME%
echo   Cores:   %CPU_CORES%
echo   RAM:     %RAM_MB% MB
echo.

REM ---- Check minimum requirements ----
if %RAM_MB% LSS 512 (
    echo [DagTech] ERROR: Insufficient RAM. Minimum 512MB required.
    pause
    exit /b 1
)

REM ---- Check for Python (required for dashboard) ----
set "PYTHON_OK=0"
python --version >nul 2>&1
if not errorlevel 1 (
    set "PYTHON_OK=1"
    for /f "tokens=*" %%v in ('python --version 2^>^&1') do echo   Python:  %%v
) else (
    python3 --version >nul 2>&1
    if not errorlevel 1 (
        set "PYTHON_OK=1"
        for /f "tokens=*" %%v in ('python3 --version 2^>^&1') do echo   Python:  %%v
    )
)
if "%PYTHON_OK%"=="0" (
    echo.
    echo [DagTech] Python not found. Installing Python for dashboard support...
    echo [DagTech] Downloading Python installer...
    powershell -Command "Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe' -OutFile '%TEMP%\python-installer.exe'"
    if exist "%TEMP%\python-installer.exe" (
        echo [DagTech] Running Python installer ^(this may take a minute^)...
        "%TEMP%\python-installer.exe" /quiet InstallAllUsers=0 PrependPath=1 Include_test=0 Include_doc=0
        echo [DagTech] Python installed. Refreshing PATH...
        REM Refresh PATH in current session
        for /f "tokens=2,*" %%a in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "PATH=%%b;%PATH%"
        python --version >nul 2>&1
        if not errorlevel 1 (
            echo [DagTech] Python is ready
            set "PYTHON_OK=1"
        ) else (
            echo [DagTech] WARNING: Python installed but PATH not updated yet.
            echo [DagTech] Dashboard will work after you restart your computer.
        )
        del "%TEMP%\python-installer.exe" 2>nul
    ) else (
        echo [DagTech] WARNING: Could not download Python. Dashboard will not be available.
        echo [DagTech] Install Python manually from https://python.org and re-run the installer.
    )
)
echo.

REM ---- Check for GPU ----
set "GPU_AVAILABLE=0"
nvidia-smi >nul 2>&1
if not errorlevel 1 (
    set "GPU_AVAILABLE=1"
    echo [DagTech] NVIDIA GPU detected
    for /f "tokens=*" %%a in ('nvidia-smi --query-gpu^=name --format^=csv^,noheader 2^>nul') do echo   GPU: %%a
)

REM ---- Verify miner binary is available ----
echo.
if exist "%~dp0bin\windows\dagtech-miner.exe" (
    echo [DagTech] Miner binary found in package
) else (
    echo [DagTech] WARNING: Miner binary not found in package - will download after config
)

REM ---- Configuration ----
echo.
echo   --- Configuration ---
echo.

:wallet_prompt
set /p "WALLET=  Enter wallet address (0x...): "
powershell -Command ^
  "$w = '%WALLET%'; " ^
  "if ($w -match '^0x[0-9a-fA-F]{40}$') { exit 0 } " ^
  "elseif ($w -notmatch '^0x') { Write-Host '[DagTech] Address must start with 0x'; exit 1 } " ^
  "elseif ($w.Length -lt 42) { Write-Host \"[DagTech] Address too short ($($w.Length) chars, need 42). Check you copied the full address.\"; exit 1 } " ^
  "elseif ($w.Length -gt 42) { Write-Host \"[DagTech] Address too long ($($w.Length) chars, need 42). Remove extra characters.\"; exit 1 } " ^
  "else { Write-Host '[DagTech] Address contains invalid characters. Use only 0-9 and a-f after 0x.'; exit 1 }"
if errorlevel 1 (
    goto :wallet_prompt
)

echo.
echo   Mining mode:
if "%GPU_AVAILABLE%"=="1" (
    echo     1^) CPU only
    echo     2^) GPU only
    echo     3^) CPU + GPU [recommended]
    echo.
    set /p "MODE_CHOICE=  Choice [1-3]: "
) else (
    echo     1^) CPU only ^(no GPU detected^)
    set "MODE_CHOICE=1"
)

set "MINING_MODE=cpu"
if "%MODE_CHOICE%"=="2" set "MINING_MODE=gpu"
if "%MODE_CHOICE%"=="3" set "MINING_MODE=both"
echo [DagTech] Mode: %MINING_MODE%

REM ---- Thread count ----
set /a "DEFAULT_THREADS=%CPU_CORES% / 2"
if %DEFAULT_THREADS% LSS 1 set "DEFAULT_THREADS=1"
echo.
set /p "THREADS=  CPU threads (1-%CPU_CORES%, default %DEFAULT_THREADS%): "
if "%THREADS%"=="" set "THREADS=%DEFAULT_THREADS%"

REM ---- Pool ----
echo.
set "POOL_HOST=excalibur.dagtech.network"
set "POOL_PORT=3335"
set /p "POOL_INPUT=  Pool address (default: %POOL_HOST%): "
if not "%POOL_INPUT%"=="" set "POOL_HOST=%POOL_INPUT%"
set /p "PORT_INPUT=  Pool port (default: %POOL_PORT%): "
if not "%PORT_INPUT%"=="" set "POOL_PORT=%PORT_INPUT%"

REM ---- Worker name ----
echo.
set "WORKER=dagtech"
set /p "WORKER_INPUT=  Worker name (default: dagtech): "
if not "%WORKER_INPUT%"=="" set "WORKER=%WORKER_INPUT%"

echo.
echo [DagTech] Configuration complete

REM ---- Create directories ----
echo [DagTech] Creating installation directories...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"
if not exist "%DASHBOARD_DIR%" mkdir "%DASHBOARD_DIR%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

REM ---- Save config ----
(
echo # DagTech Miner Configuration
echo # Generated by DagTech Installer v%DAGTECH_VERSION%
echo WALLET=%WALLET%
echo POOL_HOST=%POOL_HOST%
echo POOL_PORT=%POOL_PORT%
echo MINING_MODE=%MINING_MODE%
echo THREADS=%THREADS%
echo WORKER_NAME=%WORKER%
echo METRICS_PORT=8880
) > "%CONFIG_FILE%"
echo [DagTech] Config saved

REM ---- Install CPU miner binary ----
REM Windows always uses pre-built binary (C source requires POSIX headers)
echo [DagTech] Installing CPU miner binary...
if exist "%~dp0bin\windows\dagtech-miner.exe" (
    copy /y "%~dp0bin\windows\dagtech-miner.exe" "%BIN_DIR%\dagtech-miner.exe" >nul
    echo [DagTech] CPU miner binary installed from package
) else (
    echo [DagTech] Downloading CPU miner binary from GitHub...
    powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/bin/windows/dagtech-miner.exe' -OutFile '%BIN_DIR%\dagtech-miner.exe'"
    if exist "%BIN_DIR%\dagtech-miner.exe" (
        echo [DagTech] CPU miner binary downloaded successfully
    ) else (
        echo [DagTech] ERROR: Could not download CPU miner binary. Check internet connection.
        pause
        exit /b 1
    )
)

REM ---- Install GPU miner binary (if GPU mode selected) ----
if "%MINING_MODE%"=="gpu" goto :install_gpu
if "%MINING_MODE%"=="both" goto :install_gpu
goto :skip_gpu

:install_gpu
echo [DagTech] Installing GPU miner binary...
if exist "%~dp0bin\windows\dagtech-gpu-miner.exe" (
    copy /y "%~dp0bin\windows\dagtech-gpu-miner.exe" "%BIN_DIR%\dagtech-gpu-miner.exe" >nul
    echo [DagTech] GPU miner binary installed from package
) else (
    echo [DagTech] Downloading GPU miner binary from GitHub...
    powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/bin/windows/dagtech-gpu-miner.exe' -OutFile '%BIN_DIR%\dagtech-gpu-miner.exe'"
    if exist "%BIN_DIR%\dagtech-gpu-miner.exe" (
        echo [DagTech] GPU miner binary downloaded successfully
    ) else (
        echo [DagTech] WARNING: Could not install GPU miner binary.
        echo [DagTech] GPU mining will not be available. CPU mining will still work.
        if "%MINING_MODE%"=="gpu" set "MINING_MODE=cpu"
        if "%MINING_MODE%"=="both" set "MINING_MODE=cpu"
    )
)
:skip_gpu

REM ---- Copy dashboard ----
echo [DagTech] Installing dashboard...
if exist "%~dp0dashboard\index.html" (
    copy /y "%~dp0dashboard\index.html" "%DASHBOARD_DIR%\" >nul
)
if exist "%~dp0dashboard\dashboard_server.py" (
    copy /y "%~dp0dashboard\dashboard_server.py" "%DASHBOARD_DIR%\" >nul
)

REM ---- Copy icon ----
echo [DagTech] Installing icon...
if exist "%~dp0assets\dagtech.ico" (
    copy /y "%~dp0assets\dagtech.ico" "%INSTALL_DIR%\dagtech.ico" >nul
)

REM ---- Create launcher batch files ----
echo [DagTech] Creating launcher scripts...
if exist "%~dp0bin\windows\dagtech-start.bat" (
    copy /y "%~dp0bin\windows\dagtech-start.bat" "%BIN_DIR%\dagtech-start.bat" >nul
    copy /y "%~dp0bin\windows\dagtech-stop.bat" "%BIN_DIR%\dagtech-stop.bat" >nul
) else (
    echo [DagTech] WARNING: Launcher templates not found, downloading...
    powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/bin/windows/dagtech-start.bat' -OutFile '%BIN_DIR%\dagtech-start.bat'"
    powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/bin/windows/dagtech-stop.bat' -OutFile '%BIN_DIR%\dagtech-stop.bat'"
)

REM ---- Add to PATH ----
echo [DagTech] Adding to PATH...
echo %PATH% | findstr /i /c:"%BIN_DIR%" >nul 2>&1
if errorlevel 1 (
    setx PATH "%PATH%;%BIN_DIR%" >nul 2>&1
    echo [DagTech] PATH updated
) else (
    echo [DagTech] PATH already configured
)

REM ---- Create Desktop Shortcut ----
echo [DagTech] Creating desktop shortcut...
set "ICON_PATH=%INSTALL_DIR%\dagtech.ico"
set "SHORTCUT_TARGET=%BIN_DIR%\dagtech-start.bat"
set "DESKTOP_DIR=%USERPROFILE%\Desktop"
powershell -Command "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('%DESKTOP_DIR%\DagTech Miner.lnk'); $sc.TargetPath = '%SHORTCUT_TARGET%'; $sc.WorkingDirectory = '%BIN_DIR%'; $sc.Description = 'Start DagTech Miner'; if (Test-Path '%ICON_PATH%') { $sc.IconLocation = '%ICON_PATH%,0' }; $sc.Save()"
if errorlevel 1 (
    echo [DagTech] WARNING: Could not create desktop shortcut
) else (
    echo [DagTech] Desktop shortcut created
)

REM ---- Create Start Menu Shortcut ----
echo [DagTech] Creating Start Menu entry...
set "START_MENU_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\DagTech"
if not exist "%START_MENU_DIR%" mkdir "%START_MENU_DIR%"
powershell -Command "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('%START_MENU_DIR%\DagTech Miner.lnk'); $sc.TargetPath = '%SHORTCUT_TARGET%'; $sc.WorkingDirectory = '%BIN_DIR%'; $sc.Description = 'Start DagTech Miner'; if (Test-Path '%ICON_PATH%') { $sc.IconLocation = '%ICON_PATH%,0' }; $sc.Save(); $sc2 = $ws.CreateShortcut('%START_MENU_DIR%\Stop DagTech Miner.lnk'); $sc2.TargetPath = '%BIN_DIR%\dagtech-stop.bat'; $sc2.WorkingDirectory = '%BIN_DIR%'; $sc2.Description = 'Stop DagTech Miner'; if (Test-Path '%ICON_PATH%') { $sc2.IconLocation = '%ICON_PATH%,0' }; $sc2.Save()"
echo [DagTech] Start Menu entries created

REM ---- Done ----
echo.
echo   =============================================
echo     Installation Complete!
echo   =============================================
echo.
echo   Shortcuts created:
echo     Desktop:    DagTech Miner
echo     Start Menu: DagTech ^> DagTech Miner
echo     Start Menu: DagTech ^> Stop DagTech Miner
echo.
echo   Config: %CONFIG_FILE%
echo   Logs:   %LOG_DIR%
echo.
echo   DagTech Mining Suite v%DAGTECH_VERSION%
echo   By Dawie Nel / DagTech Ltd
echo   https://dagtech.network
echo.

REM ---- Ask to start mining now ----
echo.
set /p "START_NOW=  Start mining now? [Y/n]: "
if /i "%START_NOW%"=="n" (
    echo.
    echo   To start mining later, double-click "DagTech Miner" on your Desktop.
    echo.
    pause
    exit /b 0
)

REM ---- Launch miner ----
echo.
echo [DagTech] Starting miner...
echo [DagTech] Opening dashboard at http://localhost:8881 ...
echo.

REM Open dashboard in default browser (give it a moment to start)
start "" "%BIN_DIR%\dagtech-start.bat"
timeout /t 3 /nobreak >nul
start http://localhost:8881

echo   Mining is running! Check the dashboard in your browser.
echo   To stop mining: double-click "Stop DagTech Miner" in Start Menu
echo   or run: dagtech-stop.bat
echo.
pause
