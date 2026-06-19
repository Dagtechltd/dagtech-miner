# dagtech-mac-miner v2.1.0 GPU preview - Metal kernel

Phase B Metal MSL port. Byte-correct vs CPU reference. **130 KH/s on M1 Pro 16-core GPU.**

## Status

This directory contains the working Metal Shading Language kernel + Objective-C++ dispatcher + standalone test/bench tools + the combined v21 miner C source with --mode {cpu,gpu,both} flag. Integration into the production v2.1.0 install binary is pending pool job-flow restoration (UAE node EVM children stuck since 2026-06-18 OOM cascade).

## Files

| File | Purpose |
|---|---|
| `bdag_metal_scrypt.metal` | MSL kernel - scrypt(N=1024,r=1,p=1) + BlockDAG post-ROMix tweak. Byte-correct. |
| `bdag_metal_dispatch.mm` | Objective-C++ dispatcher, C-callable `bdag_gpu_scrypt_batch()`. |
| `metal_source.h` | MSL source embedded at compile time (no offline `metal`/`metallib` tool needed). |
| `gpu_test.mm` | Hash-equivalence test: CPU ref vs GPU output for one nonce. |
| `gpu_debug.mm` | PBKDF2 intermediate-state diff. |
| `gpu_debug_romix.mm` | scrypt ROMix intermediate-state diff. |
| `gpu_bench.mm` | Throughput bench, scaling 64..2048 threads. |
| `bdag_miner_v21.c` | Unified C miner with `--mode {cpu,gpu,both}` `--batch N` flags. |

## Bench

| Batch | V buffer | Hashrate    | Speedup vs CPU (2.4 KH/s) |
|-------|----------|-------------|---------------------------|
| 64    | 8 MB     | 13.6 KH/s   | 5.7x  |
| 128   | 16 MB    | 27.0 KH/s   | 11x   |
| 256   | 32 MB    | 50.5 KH/s   | 21x   |
| 512   | 64 MB    | 95.7 KH/s   | 40x   |
| **1024** | **128 MB** | **130.5 KH/s** | **54x** |
| 2048  | 256 MB   | 109.3 KH/s  | (memory pressure)         |

## Build

```
xcrun clang -O3 -march=armv8.5-a+crypto -c bdag_miner_v21.c \
  -I/opt/homebrew/opt/openssl@3/include \
  -Wno-deprecated-declarations -o bdag_miner_v21.o

xcrun clang++ -O3 -fobjc-arc \
  -framework Metal -framework Foundation \
  -L/opt/homebrew/opt/openssl@3/lib \
  bdag_miner_v21.o bdag_metal_dispatch.mm \
  -lcrypto -lpthread -o dagtech-mac-miner

codesign --force --sign - dagtech-mac-miner
```

## The bug that took me hours

CPU reads `(uint8_t *)X` as native endian (little on ARM/x86). My first MSL kernel read it big-endian. PBKDF2 was correct, ROMix was correct, but the X-bytes-to-uint32 conversion at the seam diverged. Fix: two byte-to-uint loops needed LE order. See git history.

Copyright (c) 2026 DagTech Ltd. CONFIDENTIAL.