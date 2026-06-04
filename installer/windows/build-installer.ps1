# DagTech Miner — Windows Installer Build Script
# Prerequisites: Inno Setup 6+ installed (https://jrsoftware.org/isinfo.php)
# Usage: .\build-installer.ps1

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path "$ScriptDir\..\.."

Write-Host "`n  DagTech Miner — Installer Build" -ForegroundColor Cyan
Write-Host "  ================================`n"

# 1. Download Python embeddable (portable, no install needed)
$PythonDir = "$ScriptDir\python-embed"
if (-not (Test-Path "$PythonDir\python.exe")) {
    Write-Host "[BUILD] Downloading Python 3.12 embeddable..." -ForegroundColor Yellow
    $PythonUrl = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip"
    $PythonZip = "$env:TEMP\python-embed.zip"
    Invoke-WebRequest -Uri $PythonUrl -OutFile $PythonZip
    if (Test-Path $PythonDir) { Remove-Item $PythonDir -Recurse -Force }
    Expand-Archive $PythonZip -DestinationPath $PythonDir -Force
    Remove-Item $PythonZip
    Write-Host "[BUILD] Python embeddable extracted to $PythonDir" -ForegroundColor Green
} else {
    Write-Host "[BUILD] Python embeddable already present" -ForegroundColor Green
}

# 2. Create dist directory
$DistDir = "$RepoRoot\dist"
if (-not (Test-Path $DistDir)) { New-Item $DistDir -ItemType Directory | Out-Null }

# 3. Ensure icon exists
$IconPath = "$RepoRoot\assets\dagtech.ico"
if (-not (Test-Path $IconPath)) {
    Write-Host "[BUILD] WARNING: dagtech.ico not found at $IconPath" -ForegroundColor Yellow
    Write-Host "[BUILD] Generate one from the SVG logo: https://dapps.dagtech.network/icon.svg" -ForegroundColor Yellow
}

# 4. Copy config wizard
Copy-Item "$ScriptDir\dagtech-config.bat" "$RepoRoot\bin\windows\dagtech-config.bat" -Force

# 5. Create LICENSE if missing
if (-not (Test-Path "$RepoRoot\LICENSE")) {
    "MIT License`n`nCopyright (c) 2024-2026 DagTech Ltd / Dawie Nel`n`nPermission is hereby granted..." | Set-Content "$RepoRoot\LICENSE"
    Write-Host "[BUILD] Created placeholder LICENSE file" -ForegroundColor Yellow
}

# 6. Create wizard images if missing
if (-not (Test-Path "$ScriptDir\wizard-large.bmp")) {
    Write-Host "[BUILD] NOTE: wizard-large.bmp (164x314) and wizard-small.bmp (55x55) not found" -ForegroundColor Yellow
    Write-Host "[BUILD] Inno Setup will use defaults. Create branded BMPs for professional look." -ForegroundColor Yellow
}

# 7. Build with Inno Setup
$ISCC = ""
$InnoPaths = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe"
)
foreach ($p in $InnoPaths) {
    if (Test-Path $p) { $ISCC = $p; break }
}

if ($ISCC) {
    Write-Host "[BUILD] Building installer with Inno Setup..." -ForegroundColor Cyan
    & $ISCC "$ScriptDir\dagtech-miner-setup.iss"
    if ($LASTEXITCODE -eq 0) {
        $Installer = Get-ChildItem "$DistDir\DagTech-Miner-*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Write-Host "`n[BUILD] SUCCESS! Installer: $($Installer.FullName)" -ForegroundColor Green
        Write-Host "[BUILD] Size: $([math]::Round($Installer.Length / 1MB, 1)) MB" -ForegroundColor Green
    } else {
        Write-Host "[BUILD] FAILED! Check Inno Setup output above." -ForegroundColor Red
    }
} else {
    Write-Host "[BUILD] Inno Setup not found. Install from https://jrsoftware.org/isinfo.php" -ForegroundColor Red
    Write-Host "[BUILD] Then run: iscc `"$ScriptDir\dagtech-miner-setup.iss`"" -ForegroundColor Yellow
}

Write-Host ""
