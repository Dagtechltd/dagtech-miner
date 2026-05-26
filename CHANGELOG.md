# Changelog

All notable changes to DagTech Miner are documented here.
This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2026-05-26

### Added
- NVIDIA CUDA GPU miner (`bdag_gpu_miner_v2`) - opt-in via `install.sh` prompt
- GPU autotune (`autotune.py`) sweeps batch x threads and persists optimal
  config per GPU signature (`gpu-miner.<sig>.json`, gitignored)
- New `bdag_gpu_miner_v2/` subdir with full CUDA sources (`hasher.cu`,
  `scrypt_cores.cu`, `bdag_stage18a_kepler_live_miner.cu`) plus build
  scripts and `BUILD.md`
- `tools/test-share.sh` placeholder (stub for upcoming `libbdag_scrypt.so`
  share-validation work)
- `GPU_WORKER_NAME` written to `config.env` (default `<worker>-gpu`)

### Changed
- Bumped version string to `2.1.0` across `README.md`, `install.sh`,
  `install-mac.sh`, `install.bat`, and `dashboard/index.html`
- `install.sh check_gpu()` now also detects `nvcc` and reports CUDA release

### Confirmed
- BDAG post-ROMix tweak applied in CUDA via `__byte_perm` canonical bswap
  (matches CPU reference path)

### Validated
- 100% share-accept rate on `cpu-gpu-pool` (24 May 2026)
- 1.89 MH/s sustained on RTX 4080 (sm_89, autotune-selected config)

### Unchanged
- CPU miner (`ref_miner` / `dagtech-miner`) - source, flags, and runtime
  behaviour are untouched
- Stratum protocol (v1, vardiff, clean_jobs semantics)
- Pool defaults: `excalibur.dagtech.network:3335`

### Known limitations
- Native Windows binary not bundled in v2.1.0 - Windows users continue to
  use WSL2 path. Native build planned for v2.2.

## [2.0.0] - 2025

Complete rewrite with cross-platform installer (Linux, macOS, Windows),
dashboard, and systemd integration. See git history for details.
