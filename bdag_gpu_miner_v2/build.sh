#!/usr/bin/env bash
set -e

nvcc --gpu-architecture sm_89 -O3 -std=c++17 -c hasher.cu -o hasher.o

nvcc --gpu-architecture sm_89 -O3 -std=c++17 \
  hasher.o bdag_stage18a_kepler_live_miner.cu \
  -o bdag_kepler_live_miner \
  -lcrypto \
  -Xcompiler -pthread

echo "Built ./bdag_kepler_live_miner"
