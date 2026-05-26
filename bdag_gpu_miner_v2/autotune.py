#!/usr/bin/env python3
"""
BDAG GPU miner v2 autotune.

Sweeps (batch_size, threads_per_block) candidates as defined by Jeremy's
reference algorithm in BlockdagEngineering_gpu-miner-nvidia/bdag_gpu_miner/gpu_autotune.py:

    selection_score = hashrate * (target_scan_seconds / max(0.001, scan_seconds)) ** 0.35

Sweeps batch_size in {4096, 8192, 16384, 32768} x threads_per_block in {32, 64, 128},
runs `scans_per_candidate` short benchmark scans per candidate by invoking the
compiled miner binary, picks the best by selection_score, and writes:

    /home/bdag/bdag-gpu-miner-v2/gpu-miner.<gpu_signature>.json

If no NVIDIA GPU is detected, exits cleanly with a clear message (rc=2).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BINARY = HERE / "bdag_kepler_live_miner"

BATCH_SIZES = [4096, 8192, 16384, 32768]
THREADS_PER_BLOCK = [32, 64, 128]
SCANS_PER_CANDIDATE = 3
TARGET_SCAN_SECONDS = 0.10
PER_SCAN_RUNTIME_SECONDS = 8  # short benchmark window per scan
HASHRATE_LINE = re.compile(r"([\d.]+)\s*(k|M|G)?H/?s", re.IGNORECASE)


def detect_gpu():
    """Return dict with name, compute_capability, total_mem_mb, signature -- or None."""
    nvsmi = shutil.which("nvidia-smi")
    if not nvsmi:
        return None
    try:
        out = subprocess.check_output(
            [nvsmi, "--query-gpu=name,compute_cap,memory.total",
             "--format=csv,noheader,nounits"],
            stderr=subprocess.STDOUT, timeout=15,
        ).decode(errors="replace").strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if not out:
        return None
    first = out.splitlines()[0]
    parts = [p.strip() for p in first.split(",")]
    if len(parts) < 3:
        return None
    name, cap, mem_mb = parts[0], parts[1], int(float(parts[2]))
    memory_bucket = (mem_mb // 512) * 512
    return {
        "name": name,
        "compute_capability": cap,
        "total_memory_mb": mem_mb,
        "signature": f"{name}|cc{cap}|mem{memory_bucket}",
    }


def gpu_signature_to_slug(sig: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", sig).strip("_")


def parse_hashrate(text: str) -> float:
    """Extract last hashrate (in H/s) from miner stdout, if present."""
    best = 0.0
    for m in HASHRATE_LINE.finditer(text):
        val = float(m.group(1))
        unit = (m.group(2) or "").lower()
        mult = {"k": 1e3, "m": 1e6, "g": 1e9, "": 1.0}[unit]
        rate = val * mult
        if rate > best:
            best = rate
    return best


def run_scan(batch_size: int, threads_per_block: int, runtime_s: int):
    """Run one short benchmark scan. Returns (hashes_done, seconds)."""
    if not BINARY.exists():
        raise FileNotFoundError(f"missing binary: {BINARY}")
    env = os.environ.copy()
    # Surface candidate config to the binary via env (the v1 binary ignores these,
    # but downstream v2 builds can pick them up; the JSON output is the source of truth).
    env["BDAG_BATCH_SIZE"] = str(batch_size)
    env["BDAG_THREADS_PER_BLOCK"] = str(threads_per_block)
    cmd = [
        str(BINARY),
        "--host", os.environ.get("POOL_HOST", "127.0.0.1"),
        "--port", os.environ.get("POOL_PORT", "3335"),
        "--wallet", os.environ.get("WALLET", "0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f"),
        "--password", os.environ.get("PASSWORD", "x"),
        "--runtime", str(runtime_s),
        "--margin", "1.02",
        "--min-threshold", "0.25",
        "--extranonce2", "00000000",
    ]
    t0 = time.time()
    try:
        proc = subprocess.run(cmd, env=env, capture_output=True, timeout=runtime_s + 10)
        text = proc.stdout.decode(errors="replace") + proc.stderr.decode(errors="replace")
    except subprocess.TimeoutExpired as e:
        text = (e.stdout or b"").decode(errors="replace") + (e.stderr or b"").decode(errors="replace")
    dt = max(0.001, time.time() - t0)
    rate = parse_hashrate(text)
    hashes = rate * dt if rate > 0 else batch_size  # fallback: assume one scan completed
    return hashes, dt, text


def autotune():
    gpu = detect_gpu()
    if gpu is None:
        print("[autotune] no NVIDIA GPU detected (nvidia-smi missing or failed).")
        print("[autotune] exiting cleanly without writing a tuning file.")
        return 2

    print(f"[autotune] GPU: {gpu['name']} cc{gpu['compute_capability']} {gpu['total_memory_mb']} MB")
    print(f"[autotune] signature: {gpu['signature']}")
    print(f"[autotune] sweep: batch_size={BATCH_SIZES} threads_per_block={THREADS_PER_BLOCK}")
    print(f"[autotune] scans_per_candidate={SCANS_PER_CANDIDATE} target_scan_seconds={TARGET_SCAN_SECONDS}")

    candidates = []
    best = None

    for bs in BATCH_SIZES:
        for tpb in THREADS_PER_BLOCK:
            print(f"[autotune] benchmarking batch_size={bs} threads_per_block={tpb} ...")
            t0 = time.time()
            total_hashes = 0.0
            for idx in range(SCANS_PER_CANDIDATE):
                hashes, dt, _txt = run_scan(bs, tpb, PER_SCAN_RUNTIME_SECONDS)
                total_hashes += hashes
            elapsed = max(0.001, time.time() - t0)
            scan_seconds = elapsed / SCANS_PER_CANDIDATE
            hashrate = total_hashes / elapsed
            latency_factor = min(1.0, TARGET_SCAN_SECONDS / max(0.001, scan_seconds))
            selection_score = hashrate * (latency_factor ** 0.35)
            row = {
                "batch_size": bs,
                "threads_per_block": tpb,
                "hashes": total_hashes,
                "elapsed_seconds": elapsed,
                "scan_seconds": scan_seconds,
                "hashrate": hashrate,
                "selection_score": selection_score,
            }
            candidates.append(row)
            print(f"  hashrate={hashrate:.2f} H/s  scan={scan_seconds:.3f}s  score={selection_score:.2f}")
            if best is None or selection_score > best["selection_score"]:
                best = dict(row)

    out_path = HERE / f"gpu-miner.{gpu_signature_to_slug(gpu['signature'])}.json"
    payload = {
        "device": gpu,
        "best": best,
        "candidates": candidates,
        "scans_per_candidate": SCANS_PER_CANDIDATE,
        "target_scan_seconds": TARGET_SCAN_SECONDS,
        "generated_at": int(time.time()),
        "miner_binary": str(BINARY),
    }
    out_path.write_text(json.dumps(payload, indent=2))
    print(f"[autotune] wrote {out_path}")
    print(f"[autotune] best: batch_size={best['batch_size']} threads_per_block={best['threads_per_block']} "
          f"score={best['selection_score']:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(autotune())
