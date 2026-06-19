# dagtech-mac-miner

**One-liner CPU miner for BlockDAG on Apple Silicon Macs.**

```bash
curl -fsSL https://miner.dagtech.network/mac/install.sh | bash
```

That is the entire install. The script:

1. Detects macOS + Apple Silicon (arm64)
2. Installs Xcode Command Line Tools, Homebrew, and openssl@3 if missing
3. Downloads the verified binary (SHA256 chain)
4. Ad-hoc codesigns it for Gatekeeper
5. Asks for your wallet address, worker name, and thread count
6. Writes config to `~/.dagtech-miner/config.json`
7. Registers two launchd services (miner + dashboard)
8. Starts mining and opens the dashboard at <http://127.0.0.1:8881>

No Apple Developer account, no manual permission grants, no Terminal proficiency required.

---

## What you get

- **Mining daemon** running under `launchctl`, auto-restart on crash, survives reboot
- **Live dashboard** at <http://127.0.0.1:8881> showing hashrate, shares, jobs, difficulty, worker name, wallet
- **Default pool**: `excalibur.dagtech.network:3335` (CPU/GPU tier, PPLNS payout, low starting difficulty)

## System requirements

| Item    | Minimum             | Recommended                |
|---------|---------------------|----------------------------|
| OS      | macOS 12 (Monterey) | macOS 14 (Sonoma) or later |
| CPU     | Apple Silicon (M1+) | M1 Pro / M2 / M3           |
| RAM     | 8 GB                | 16 GB                      |
| Disk    | 200 MB free         | -                          |

Intel Macs are not supported in v0.1. v0.2 adds Metal GPU acceleration. v0.3 adds Intel.

## Uninstall

```bash
curl -fsSL https://miner.dagtech.network/mac/uninstall.sh | bash
```

## Files placed on your machine

```
~/.dagtech-miner/
  bin/dagtech-mac-miner-cpu       (70 KB, ad-hoc signed)
  config.json                     (wallet, worker, threads, pool)
  dashboard.py                    (sidecar)
  miner.log                       (rolling)
  dashboard.log

~/Library/LaunchAgents/
  network.dagtech.miner.plist
  network.dagtech.miner.dashboard.plist
```

## Verifying the binary

```bash
shasum -a 256 ~/.dagtech-miner/bin/dagtech-mac-miner-cpu
# expected: c9222f7e022ab06c17d785ca44d737bd7580391c95e76ee5748ef06a71c202bf
```

The install script verifies this automatically. SHA mismatch refuses to install.

## Build from source

```bash
brew install openssl@3
clang -O3 -march=armv8.5-a+crypto -mtune=native \
  -I/opt/homebrew/opt/openssl@3/include \
  -L/opt/homebrew/opt/openssl@3/lib \
  -o dagtech-mac-miner-cpu \
  bdag_cpu_miner.c \
  -lpthread -lssl -lcrypto
codesign --force --sign - --timestamp=none dagtech-mac-miner-cpu
```

## Reproducibility

v2.1.0 validated against a 10-iteration install/verify/uninstall loop on a clean M1 Pro running macOS 26.5. Each pass tears down, runs install.sh non-interactively, waits 8s, then verifies launchctl PIDs, dashboard `/api/stats` returns 200, miner.log shows mining activity, dashboard worker name matches config.

Score: **10/10 passed, 0/10 failed.**

## Releases

| Version | Date       | Notes                                                  |
|---------|------------|--------------------------------------------------------|
| v2.1.0    | 2026-06-19 | First public release. CPU-only. Apple Silicon. 10/10.  |
| v0.2    | TBD        | Metal GPU acceleration (MSL keccak port).              |
| v0.3    | TBD        | Intel Mac + automatic algorithm switching.             |

## Support

- DagTech pool: <https://miner.dagtech.network>
- Issues: <https://github.com/Dagtechltd/dagtech-miner/issues>

---

Copyright (c) 2026 DagTech Ltd. CONFIDENTIAL.