# BDAG GPU Miner

Experimental CUDA GPU miner for the BlockDAG network.

This miner is designed for Linux machines with NVIDIA GPUs. It has been tested on a fresh Vast.ai GPU instance using an RTX 3060.

## What this does

This miner connects to a BlockDAG mining pool, receives mining jobs, scans nonces using a CUDA GPU, and submits valid shares back to the pool.

The miner is configured using a simple `.env` file, so users do not need to edit the source code to change their wallet or pool settings.

## Requirements

You need:

- Linux / Ubuntu GPU server
- NVIDIA GPU
- NVIDIA drivers
- CUDA toolkit / `nvcc`
- `git`
- `make`
- Internet access
- A BlockDAG-compatible wallet address starting with `0x`

This is intended for GPU VPS platforms such as Vast.ai, RunPod, or your own CUDA Linux machine.

## Quick start

Clone the repo:

```bash
git clone https://github.com/loftedplacebo/bdag-gpu-miner.git
cd bdag-gpu-miner

Create your local environment file:

cp .env.example .env
nano .env

Edit your wallet address:

WALLET=0xYourWalletAddressHere

Then build and run:

chmod +x build.sh run.sh run_my_pool.sh
./build.sh
./run.sh
Configuration

All user settings are controlled through .env.

Example:

POOL_HOST=62.171.161.32
POOL_PORT=3334
WALLET=0xYourWalletAddressHere
WORKER_NAME=gpu01
RUNTIME_SECONDS=300
MARGIN=0.99
MIN_THRESHOLD=0.01
Settings explained
Setting	Description
POOL_HOST	Mining pool hostname or IP address
POOL_PORT	Mining pool stratum port
WALLET	Your BlockDAG-compatible wallet address
WORKER_NAME	Optional worker name for identifying your GPU
RUNTIME_SECONDS	How long the miner should run before stopping
MARGIN	Share threshold margin
MIN_THRESHOLD	Minimum share threshold
Wallet setup

Your wallet should be an EVM-style address:

0x0000000000000000000000000000000000000000

The miner will reject obviously invalid wallet values.

Do not edit the source code to change wallet details. Edit .env only.

Tested Vast.ai setup

A simple first test can be done using:

1× RTX 3060
Ubuntu 22.04
CUDA image
Fresh instance

Example setup commands:

cd /workspace || cd /root
git clone https://github.com/loftedplacebo/bdag-gpu-miner.git
cd bdag-gpu-miner

cp .env.example .env
nano .env

chmod +x build.sh run.sh run_my_pool.sh
./build.sh
./run.sh
Checking your GPU

Before building, check that the GPU is visible:

nvidia-smi

Check that CUDA compiler is available:

nvcc --version

If nvidia-smi works but nvcc is missing, use a CUDA development image or install the CUDA toolkit.

Expected behaviour

When running correctly, the miner should:

connect to the pool
subscribe / authorise
receive jobs
scan nonces on the GPU
submit valid shares
show accepted shares in the console or pool logs

A small number of stale shares can happen if jobs change quickly.

Common issues
nvcc: command not found

The CUDA compiler is missing. Use a CUDA development image, not only a runtime image.

Invalid wallet error

Check that your wallet starts with 0x and is 42 characters long.

Cannot connect to pool

Check:

pool host
pool port
firewall rules
VPS network access
Permission denied running scripts

Run:

chmod +x build.sh run.sh run_my_pool.sh
Important warning

This is experimental mining software.

Use at your own risk. No guarantee is made around profitability, compatibility, uptime, rewards, or correctness on every machine.

You are responsible for checking that your wallet, pool settings, and mining environment are correct.

Project status

Current status:

public GitHub clone tested
.env configuration tested
fresh Vast.ai GPU build tested
RTX 3060 test completed successfully
Licence

No licence has currently been selected. All rights reserved unless a licence is added later.
'@ | Set-Content README.md