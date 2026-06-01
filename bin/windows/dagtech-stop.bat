@echo off
set "stopped=0"
taskkill /f /im dagtech-miner.exe 2>nul && set "stopped=1"
taskkill /f /im dagtech-gpu-miner.exe 2>nul && set "stopped=1"
taskkill /f /fi "WINDOWTITLE eq DagTech GPU Miner" 2>nul
if "%stopped%"=="1" (echo [DagTech] Miner stopped) else (echo [DagTech] Miner not running)
