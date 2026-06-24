#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-DagTech-Proprietary
# Copyright (c) 2026 DagTech Ltd. All rights reserved.
# Product: DagTech BlockDAG Node
# Release: v2.0.1 (Clean-Room Corruption-Proof)
# Author : DagTech Build
# CONFIDENTIAL - DagTech IP
#
# One-shot installer for DagTech BlockDAG Node v2.0.1.
# Usage: curl -fsSL https://miner.dagtech.network/v201/install.sh | bash

set -euo pipefail

VERSION="v2.0.1"
BASE_URL="https://miner.dagtech.network/v201"
SNAPSHOT_URL="https://miners.dagtech.network/snapshot/latest.tar.zst"
SNAPSHOT_SHA_URL="https://miners.dagtech.network/snapshot/SHA256SUMS"
IPFS_GATEWAY="https://ipfs.io"
IPNS_NAME="blockdag-snapshot.dagtech.network"
INSTALL_DIR="${DAGTECH_PREFIX:-/opt/dagtech-node}"
DATA_DIR="${DAGTECH_DATA:-$HOME/.dagtech-node/data}"
LOG_DIR="/var/log/dagtech-node"
STRATUM_ENDPOINT="excalibur.dagtech.network:3334"

BLUE='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { printf "${BLUE}[install]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[ ok ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
die()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; exit 1; }

# --- BANNER --------------------------------------------------------------
cat <<'BANNER'
   ____             _____         _
  |  _ \  __ _ __ _|_   _|__  ___| |__
  | | | |/ _` / _` | | |/ _ \/ __| '_ \
  | |_| | (_| \__, | | |  __/ (__| | | |
  |____/ \__,_|___/ |_|\___|\___|_| |_|
       BlockDAG Node v2.0.1 - Corruption-Proof Release
BANNER
echo ""

# --- DETECT OS + ARCH ----------------------------------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "unsupported architecture: $ARCH_RAW" ;;
esac
[ "$OS" = "linux" ] || die "this installer is for Linux; for Windows download dagtech-node-${VERSION}-windows-amd64.exe directly"

BINARY="dagtech-node-${VERSION}-${OS}-${ARCH}"
log "platform: ${OS}/${ARCH} -> ${BINARY}"

# --- PRE-FLIGHT ----------------------------------------------------------
log "pre-flight checks..."

# RAM check (need >= 8 GB)
if [ -r /proc/meminfo ]; then
  KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  GB="$((KB / 1024 / 1024))"
  [ "$GB" -ge 8 ] || die "need >= 8 GB RAM (found ${GB} GB)"
  ok "RAM: ${GB} GB"
fi

# Disk check (need >= 50 GB free where DATA_DIR will live)
PARENT="$(dirname "$DATA_DIR")"
mkdir -p "$PARENT"
AVAIL_KB="$(df -P "$PARENT" | awk 'NR==2 {print $4}')"
AVAIL_GB="$((AVAIL_KB / 1024 / 1024))"
[ "$AVAIL_GB" -ge 50 ] || die "need >= 50 GB free at ${PARENT} (found ${AVAIL_GB} GB)"
ok "disk: ${AVAIL_GB} GB free at ${PARENT}"

# Tools
for t in curl sha256sum tar; do
  command -v "$t" >/dev/null || die "missing required tool: $t"
done
ok "required tools present"

# Outbound TCP 8130 (P2P) - non-fatal warning, NAT may block but cloud relays handle this
if command -v timeout >/dev/null && command -v nc >/dev/null; then
  if timeout 5 bash -c "echo > /dev/tcp/excalibur.dagtech.network/3334" 2>/dev/null; then
    ok "stratum endpoint reachable: ${STRATUM_ENDPOINT}"
  else
    warn "stratum endpoint ${STRATUM_ENDPOINT} not reachable - check firewall after install"
  fi
fi

# --- DIRS ----------------------------------------------------------------
log "preparing directories..."
sudo mkdir -p "$INSTALL_DIR" "$LOG_DIR" || mkdir -p "$INSTALL_DIR" "$LOG_DIR" 2>/dev/null || die "cannot create install dirs"
mkdir -p "$DATA_DIR"
ok "install dir : $INSTALL_DIR"
ok "data dir    : $DATA_DIR"
ok "log dir     : $LOG_DIR"

# --- DOWNLOAD ------------------------------------------------------------
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

log "downloading binary..."
curl -fL --progress-bar -o "${TMPD}/${BINARY}" "${BASE_URL}/${BINARY}" \
  || die "download failed: ${BASE_URL}/${BINARY}"

log "downloading SHA256SUMS..."
curl -fL --silent -o "${TMPD}/SHA256SUMS" "${BASE_URL}/SHA256SUMS" \
  || die "download failed: ${BASE_URL}/SHA256SUMS"

# --- VERIFY --------------------------------------------------------------
log "verifying SHA-256..."
cd "$TMPD"
if sha256sum -c SHA256SUMS --ignore-missing 2>&1 | grep -q "${BINARY}: OK"; then
  ok "signature verified: ${BINARY}"
else
  die "SHA-256 mismatch for ${BINARY} - refusing to install"
fi
cd - >/dev/null

# Optional GPG verify
if curl -fL --silent --head "${BASE_URL}/SHA256SUMS.asc" >/dev/null 2>&1 && command -v gpg >/dev/null; then
  log "GPG signature found, verifying..."
  curl -fL --silent -o "${TMPD}/SHA256SUMS.asc" "${BASE_URL}/SHA256SUMS.asc" || true
  if gpg --verify "${TMPD}/SHA256SUMS.asc" "${TMPD}/SHA256SUMS" 2>/dev/null; then
    ok "GPG signature verified"
  else
    warn "GPG signature could not be verified (key may not be imported) - SHA-256 already passed"
  fi
fi

# --- INSTALL -------------------------------------------------------------
log "installing binary to ${INSTALL_DIR}..."
if [ -w "$INSTALL_DIR" ]; then
  install -m 0755 "${TMPD}/${BINARY}" "${INSTALL_DIR}/dagtech-node"
else
  sudo install -m 0755 "${TMPD}/${BINARY}" "${INSTALL_DIR}/dagtech-node"
fi
ok "installed: ${INSTALL_DIR}/dagtech-node"

# Symlink to /usr/local/bin
if [ ! -e /usr/local/bin/dagtech-node ]; then
  sudo ln -sf "${INSTALL_DIR}/dagtech-node" /usr/local/bin/dagtech-node 2>/dev/null \
    || ln -sf "${INSTALL_DIR}/dagtech-node" /usr/local/bin/dagtech-node 2>/dev/null \
    || warn "could not symlink to /usr/local/bin/dagtech-node - call ${INSTALL_DIR}/dagtech-node directly"
fi

# Version sanity
if "${INSTALL_DIR}/dagtech-node" --version 2>/dev/null | grep -q "v2.0.1\|2\.0\.1"; then
  ok "version sanity check passed"
else
  warn "version flag did not echo 2.0.1 - binary may differ from expected"
fi

# --- CONFIG --------------------------------------------------------------
CONF="${HOME}/.dagtech-node/config.toml"
mkdir -p "$(dirname "$CONF")"
if [ ! -f "$CONF" ]; then
  log "writing default config to ${CONF}..."
  # Prompt for wallet (skip if non-interactive)
  if [ -t 0 ]; then
    read -r -p "Mining wallet address (0x...): " WALLET || WALLET=""
  else
    WALLET=""
  fi
  if [ -z "$WALLET" ]; then
    WALLET="0x0000000000000000000000000000000000000000"
    warn "no wallet provided - placeholder written to ${CONF}; edit before mining"
  fi
  cat > "$CONF" <<EOF
# DagTech BlockDAG Node v2.0.1 config
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

[node]
data_dir = "${DATA_DIR}"
network  = "mainnet"

[rpc]
http_addr = "127.0.0.1"
http_port = 18545
ws_addr   = "127.0.0.1"
ws_port   = 18546

[p2p]
listen_port = 8130

[mining]
wallet = "${WALLET}"

[state]
# New in v2.0.1: tune to RAM. 256 default, 128 lean, 512 aggressive.
diff_layers_max = 256
EOF
  ok "config written: ${CONF}"
else
  ok "existing config preserved: ${CONF}"
fi

# --- SNAPSHOT (corruption-proof: HTTPS first, IPFS fallback) -------------
log "pulling chain snapshot (skip multi-day resync)..."
SNAP_FILE="${DATA_DIR}/snapshot.tar.zst"
SNAP_OK="no"

# Primary: direct HTTPS from miners.dagtech.network (CF tunnel + UAE nginx)
log "downloading from ${SNAPSHOT_URL} ..."
if curl -fL --progress-bar -o "$SNAP_FILE" "$SNAPSHOT_URL"; then
  log "verifying SHA-256..."
  curl -fL --silent -o "${SNAP_FILE}.sums" "$SNAPSHOT_SHA_URL" || true
  if [ -f "${SNAP_FILE}.sums" ]; then
    EXPECTED=$(awk '{print $1}' "${SNAP_FILE}.sums")
    ACTUAL=$(sha256sum "$SNAP_FILE" | awk '{print $1}')
    if [ "$EXPECTED" = "$ACTUAL" ]; then
      ok "snapshot SHA-256 verified"
      SNAP_OK="yes"
    else
      warn "snapshot SHA-256 mismatch (expected ${EXPECTED}, got ${ACTUAL}); discarding"
      rm -f "$SNAP_FILE"
    fi
    rm -f "${SNAP_FILE}.sums"
  else
    warn "SHA256SUMS unavailable; using snapshot without verify"
    SNAP_OK="yes"
  fi
else
  warn "HTTPS snapshot pull failed; trying IPFS fallback"
fi

# Fallback: IPFS gateway (in case snapshot.dagtech.network ever goes down)
if [ "$SNAP_OK" = "no" ] && command -v ipfs >/dev/null 2>&1; then
  log "using local IPFS..."
  if ipfs get "/ipns/${IPNS_NAME}" --output="$SNAP_FILE" 2>&1 | tail -3; then
    SNAP_OK="yes"
  else
    warn "IPFS pull failed"
  fi
fi

if [ "$SNAP_OK" = "no" ]; then
  warn "snapshot pull failed - node will resync from genesis (~2.7d). Continuing anyway."
fi

if [ "$SNAP_OK" = "yes" ]; then
  log "extracting snapshot..."
  if command -v zstd >/dev/null; then
    tar --use-compress-program=unzstd -xf "$SNAP_FILE" -C "$DATA_DIR" && ok "snapshot extracted"
    rm -f "$SNAP_FILE"
  else
    warn "zstd not installed - leaving snapshot at ${SNAP_FILE}; install zstd and extract manually"
  fi
fi

# --- LOCAL DASHBOARD (privacy-first, no phone-home) ---------------------
log "installing local dashboard (no telemetry, 127.0.0.1 only)..."
mkdir -p "$HOME/.dagtech-node"
DASH_HTML_URL="${BASE_URL}/dashboard.html"
DASH_PY_URL="${BASE_URL}/server.py"
if curl -fsSL -o "$HOME/.dagtech-node/dashboard.html" "$DASH_HTML_URL" \
   && curl -fsSL -o "$HOME/.dagtech-node/server.py" "$DASH_PY_URL"; then
  ok "dashboard files downloaded"
else
  warn "dashboard fetch failed - skipping local dashboard"
fi

# Write version stamp the dashboard's /version endpoint reads
echo "v2.0.1" > "$HOME/.dagtech-node/VERSION"

# Start it: prefer systemd-user, fallback to nohup
DASH_STARTED="no"
if command -v systemctl >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$HOME/.config" ]; then
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/dagtech-node-dashboard.service" <<UNIT_EOF
[Unit]
Description=DagTech BlockDAG Node - Local Dashboard (privacy-first, 127.0.0.1:8881)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 %h/.dagtech-node/server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT_EOF
  if systemctl --user daemon-reload >/dev/null 2>&1 \
     && systemctl --user enable --now dagtech-node-dashboard.service >/dev/null 2>&1; then
    ok "dashboard service started (systemd --user)"
    DASH_STARTED="yes"
  fi
fi
if [ "$DASH_STARTED" = "no" ] && [ -f "$HOME/.dagtech-node/server.py" ]; then
  # fallback: background process
  pkill -f "dagtech-node/server.py" >/dev/null 2>&1 || true
  nohup python3 "$HOME/.dagtech-node/server.py" >"$HOME/.dagtech-node/server.log" 2>&1 &
  disown 2>/dev/null || true
  ok "dashboard started (background process)"
  DASH_STARTED="yes"
fi

# Try to open it in a browser
if [ "$DASH_STARTED" = "yes" ]; then
  sleep 2
  DASH_URL="http://127.0.0.1:8881"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$DASH_URL" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$DASH_URL" >/dev/null 2>&1 &
  elif command -v cmd.exe >/dev/null 2>&1; then cmd.exe /c start "$DASH_URL" >/dev/null 2>&1 &
  fi
fi


# --- FINAL ---------------------------------------------------------------
echo ""
ok "Install complete."
echo ""
cat <<EONOTE
  Next steps:

    1. Verify wallet in     ${CONF}
    2. Start the node:      ${INSTALL_DIR}/dagtech-node --config "${CONF}"
    3. (Recommended) install as systemd service:
         sudo curl -fL -o /etc/systemd/system/dagtech-node.service \\
           ${BASE_URL}/dagtech-node.service
         sudo systemctl daemon-reload && sudo systemctl enable --now dagtech-node
    4. Point your miner at  ${STRATUM_ENDPOINT}
    5. First share expected within 30 minutes of full DAG sync.
    6. Local dashboard:     http://127.0.0.1:8881 (privacy-first, on YOUR box)

  Stuck?
    Logs: ${LOG_DIR}/  or  journalctl -u dagtech-node -f
    Docs: https://miner.dagtech.network/v201/
    If you see "missing trie node" or "illegal withdrawal at block X",
    DO NOT use --cleanup. Use the new --rescue flag instead:
      ${INSTALL_DIR}/dagtech-node --config "${CONF}" --rescue

EONOTE
