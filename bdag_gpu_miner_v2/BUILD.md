# Building bdag_gpu_miner_v2 (CUDA)

Opt-in NVIDIA GPU miner for DagTech v2.1. CPU miner (`ref_miner`) is unaffected.

## Requirements
- NVIDIA GPU with CUDA Compute Capability >= 3.5 (Kepler or newer; validated on RTX 4080 / sm_89)
- CUDA Toolkit >= 11.0 with `nvcc` on `PATH`
- `gcc`/`g++` host compiler matching the CUDA toolkit
- `libssl-dev` (OpenSSL headers for SHA-256)
- Linux x86_64 (Ubuntu 20.04+ / Debian 11+ tested)

## Build
```bash
cd bdag_gpu_miner_v2
./build.sh        # convenience wrapper
# or:
make              # explicit
```

Expected output: an executable `bdag_kepler_live_miner` in the same directory.

## Configure & run
```bash
cp .env.example .env
$EDITOR .env      # set POOL_HOST, POOL_PORT, WORKER_NAME, WALLET
./run.sh          # connects to pool, starts mining
```

The first time the miner sees a new GPU it runs `autotune.py` to sweep batch x
threads and persists the optimal config to `gpu-miner.<gpu-signature>.json`
(gitignored).

## Troubleshooting

- **`unsupported gpu architecture 'compute_XX'`** — your CUDA toolkit is older
  than your GPU. Upgrade CUDA or edit `Makefile` `-gencode` flags to match a
  supported `sm_<arch>`.
- **`out of memory` during batch sizing** — lower `BATCH_SIZE` in `.env` or
  delete the `gpu-miner.*.json` cache and let autotune re-pick.
- **`nvcc: command not found`** — install CUDA Toolkit and `export PATH=/usr/local/cuda/bin:$PATH`.
- **Link error `-lssl`/`-lcrypto`** — `sudo apt install libssl-dev`.
