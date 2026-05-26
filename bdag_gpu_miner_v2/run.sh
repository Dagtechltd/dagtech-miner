#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$EXAMPLE_FILE" ]]; then
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    echo "Created .env from .env.example"
    echo "Edit .env and set your WALLET before running again."
    exit 1
  else
    echo "Missing .env and .env.example" >&2
    exit 1
  fi
fi

# Load simple KEY=VALUE lines from .env
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${POOL_HOST:=62.171.161.32}"
: "${POOL_PORT:=3334}"
: "${WALLET:=}"
: "${PASSWORD:=x}"
: "${RUNTIME_SECONDS:=600}"
: "${SUBMIT_MARGIN:=1.02}"
: "${MIN_SUBMIT_THRESHOLD:=0.25}"
: "${EXTRANONCE2_HEX:=00000000}"

if [[ ! "$WALLET" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
  echo "Invalid WALLET in .env" >&2
  echo "Expected a 42-character EVM-style address, e.g. 0xabc...123" >&2
  exit 1
fi

if [[ "$WALLET" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "Please replace the placeholder WALLET in .env before mining." >&2
  exit 1
fi

if [[ ! -x ./bdag_kepler_live_miner ]]; then
  echo "Missing executable ./bdag_kepler_live_miner" >&2
  echo "Run ./build.sh first, or download a release package that includes the binary." >&2
  exit 1
fi

echo "BDAG GPU Miner"
echo "Pool:   ${POOL_HOST}:${POOL_PORT}"
echo "Wallet: ${WALLET:0:8}...${WALLET: -6}"
echo "Runtime: ${RUNTIME_SECONDS}s"
echo

exec ./bdag_kepler_live_miner \
  --host "$POOL_HOST" \
  --port "$POOL_PORT" \
  --wallet "$WALLET" \
  --password "$PASSWORD" \
  --runtime "$RUNTIME_SECONDS" \
  --margin "$SUBMIT_MARGIN" \
  --min-threshold "$MIN_SUBMIT_THRESHOLD" \
  --extranonce2 "$EXTRANONCE2_HEX"
