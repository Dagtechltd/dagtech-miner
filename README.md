# DagTech Miner

High-performance mining software for the DagTech Network. CPU mining with built-in dashboard, simple installation, and automatic hardware detection.

**By Dawie Nel / DagTech Ltd** — [dagtech.network](https://dagtech.network)

## Quick Start

### Linux
```bash
git clone https://github.com/Dagtechltd/dagtech-miner.git
cd dagtech-miner
chmod +x install.sh
./install.sh
```

### macOS
```bash
git clone https://github.com/Dagtechltd/dagtech-miner.git
cd dagtech-miner
chmod +x install-mac.sh
./install-mac.sh
```

### Windows
```cmd
git clone https://github.com/Dagtechltd/dagtech-miner.git
cd dagtech-miner
install.bat
```

The installer will:
1. Check your hardware (CPU cores, RAM, GPU availability)
2. Ask for your wallet address
3. Let you choose CPU, GPU, or both
4. Build the miner (Linux/Mac) or use the pre-built binary (Windows — no compiler needed)
5. Set up the dashboard and launcher scripts

## After Installation

| OS | Start | Stop |
|---|---|---|
| Linux/Mac | `dagtech-start` | `dagtech-stop` |
| Windows | `dagtech-start.bat` | `dagtech-stop.bat` |

> **Note:** On Windows, open a **new** terminal window after installation for the PATH to take effect. Or run directly: `%USERPROFILE%\.dagtech-miner\bin\dagtech-start.bat`

## Manual Build (Linux/Mac only)

```bash
make
./dagtech-miner --wallet 0xYOUR_WALLET_ADDRESS
```

## Usage

```
dagtech-miner [options]

Options:
  --wallet <addr>      Your wallet address (REQUIRED)
  --pool <host>        Pool hostname (default: excalibur.dagtech.network)
  --port <n>           Pool port (default: 3334)
  --threads <n>        Mining threads (default: auto-detect)
  --worker <name>      Worker name (default: dagtech)
  --low-priority       Run at lowest CPU priority
  --metrics-port <n>   Dashboard metrics port (default: 8880)
  --help               Show help
```

## Dashboard

The built-in dashboard runs at `http://localhost:8881` while the miner is active. It shows real-time hashrate, shares, uptime, and connection info.

## System Requirements

- **Minimum**: 2 CPU cores, 512 MB RAM
- **Recommended**: 4+ CPU cores, 2 GB+ RAM
- **Linux**: Ubuntu 20.04+, Debian 11+, Fedora 36+, Arch (gcc auto-installed)
- **macOS**: 11+ (Big Sur), Intel or Apple Silicon (Xcode CLT required)
- **Windows**: 10+ (no compiler needed — pre-built binary included)

## Configuration

Configuration is stored in `~/.dagtech-miner/config.env`. Edit it to change pool, wallet, or thread count without reinstalling.

## License

MIT License — Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
