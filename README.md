# DagTech Miner v2.1.0

CPU/GPU mining software for the BlockDAG Network (QNG/MeerDAG consensus). Uses scrypt(N=1024, r=1, p=1) with BDAG post-ROMix tweak. Connects to pool via stratum protocol. One-command install, built-in dashboard, zero configuration headaches.

## Features

- Multi-threaded scrypt mining with BDAG post-ROMix tweak
- GPU mining support (NVIDIA CUDA, AMD ROCm)
- Stratum V1 protocol (subscribe, authorize, submit)
- Built-in HTTP metrics server (JSON endpoint)
- Web dashboard with real-time hashrate, shares, balance, charts
- Auto-reconnection with exponential backoff
- Cross-platform: macOS (ARM/x86), Linux, Windows (WSL)
- One-command installer with auto-prerequisite detection

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/install.sh | bash
```

Or download and run manually:

```bash
wget https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/install.sh
bash install.sh
```

The installer will:
1. Detect your OS and architecture
2. Check/install prerequisites (C compiler, OpenSSL, Python3)
3. Prompt for wallet address, worker name, pool, threads
4. Compile the miner from source
5. Set up dashboard and management scripts

## Usage

```bash
# Start mining + dashboard
~/.dagtech-miner/run_miner.sh

# Stop
~/.dagtech-miner/stop_miner.sh

# Uninstall
~/.dagtech-miner/uninstall.sh
```

## Dashboard

Open http://localhost:8881 after starting. Shows:
- Real-time hashrate and share acceptance rate
- Wallet balance (from RPC)
- CPU usage and temperature
- Estimated daily earnings
- Hashrate and shares history charts

## Manual Build

```bash
cc -O2 -o ref_miner src/dagtech_miner.c -lssl -lcrypto -lpthread

./ref_miner --host excalibur.dagtech.network --port 3335 \
  --wallet YOUR_WALLET --worker myrig --threads 8
```

## CLI Options

| Flag | Default | Description |
|------|---------|-------------|
| --host | 127.0.0.1 | Pool hostname |
| --port | 3335 | Pool stratum port |
| --wallet | - | Your BDAG wallet address |
| --worker | default | Worker name |
| --threads | 8 | Mining threads |
| --metrics-port | 8880 | HTTP metrics port |
| --password | x | Stratum password |

## Pool Connection

Default pool: `excalibur.dagtech.network:3335` (CPU/GPU port)

The miner connects via stratum V1 protocol. CPU miners should use port 3335 (lower difficulty, PPLNS payout) rather than the ASIC port 3334.

## Requirements

- C compiler (gcc/clang)
- OpenSSL development libraries
- Python 3 (for dashboard)
- macOS: Xcode Command Line Tools + Homebrew OpenSSL
- Linux: `build-essential libssl-dev python3`
- Windows: WSL2 with Ubuntu

## License

MIT License - see LICENSE file.
