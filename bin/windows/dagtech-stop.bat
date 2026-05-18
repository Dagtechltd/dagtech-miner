@echo off
taskkill /f /im dagtech-miner.exe 2>nul && echo [DagTech] Miner stopped || echo [DagTech] Miner not running
