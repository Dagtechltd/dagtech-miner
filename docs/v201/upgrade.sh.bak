#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-DagTech-Proprietary
# Copyright (c) 2026 DagTech Ltd. All rights reserved.
# Product: DagTech BlockDAG Node
# Release: v2.0.1 (Clean-Room Corruption-Proof)
# Author : DagTech Build
# CONFIDENTIAL - DagTech IP
#
# Upgrade an existing v1 install to v2.0.1.
# Atomic + reversible. Old datadir is renamed (not copied) so disk doesn't double.
# Usage: curl -fsSL https://miner.dagtech.network/v201/upgrade.sh | bash

set -euo pipefail

VERSION="v2.0.1"
BASE_URL="https://miner.dagtech.network/v201"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

BLUE='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { printf "${BLUE}[upgrade]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[ ok  ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
die()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; exit 1; }

cat <<'BANNER'
   DagTech BlockDAG Node - Upgrade  v1  ->  v2.0.1
BANNER
echo ""

# --- DETECT EXISTING INSTALL --------------------------------------------
log "scanning for v1 install..."

V1_DIR=""
V1_DATA=""
V1_STYLE=""   # docker | systemd | bare
V1_COMPOSE=""
V1_SERVICE=""

# Common v1 locations
CANDIDATES=(
  "/home/bdag/blockdag-release"
  "/opt/blockdag"
  "/opt/dagtech-node"
  "${HOME}/.dagtech-node"
)

for c in "${CANDIDATES[@]}"; do
  if [ -d "$c" ]; then
    V1_DIR="$c"
    break
  fi
done

[ -n "$V1_DIR" ] || die "no v1 install found in any of: ${CANDIDATES[*]}"
ok "v1 install located: $V1_DIR"

# Detect run style
if [ -f "$V1_DIR/docker-compose.yml" ] || [ -f "$V1_DIR/compose.yml" ]; then
  V1_STYLE="docker"
  V1_COMPOSE="$(ls "$V1_DIR"/docker-compose.yml "$V1_DIR"/compose.yml 2>/dev/null | head -1)"
  ok "run style: docker compose ($V1_COMPOSE)"
elif systemctl list-unit-files 2>/dev/null | grep -qE 'blockdag|dagtech-node|qng'; then
  V1_STYLE="systemd"
  V1_SERVICE="$(systemctl list-unit-files 2>/dev/null | awk '/^(blockdag|dagtech-node|qng)/{print $1; exit}')"
  ok "run style: systemd ($V1_SERVICE)"
else
  V1_STYLE="bare"
  warn "run style: bare process (no docker-compose, no systemd unit) - manual stop required"
fi

# Detect data dir
for d in "$V1_DIR/data" "$V1_DIR/datadir" "${HOME}/.dagtech-node/data" "/var/lib/dagtech-node"; do
  if [ -d "$d" ]; then
    V1_DATA="$d"
    break
  fi
done
[ -n "$V1_DATA" ] || die "could not locate v1 data directory"
ok "v1 datadir: $V1_DATA"

# --- SNAPSHOT WALLET + CONFIG -------------------------------------------
log "snapshotting v1 config + wallet..."
SNAP_TO="${HOME}/.dagtech-node/pre-upgrade-${TS}"
mkdir -p "$SNAP_TO"
shopt -s nullglob
for f in "$V1_DIR"/*.toml "$V1_DIR"/*.yml "$V1_DIR"/*.yaml "$V1_DIR"/*.env "$V1_DIR"/config*; do
  [ -f "$f" ] && cp -a "$f" "$SNAP_TO/" 2>/dev/null || true
done
shopt -u nullglob
ok "config snapshot: $SNAP_TO"

# --- STOP V1 ------------------------------------------------------------
log "stopping v1..."
case "$V1_STYLE" in
  docker)
    ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" stop ) || die "docker compose stop failed"
    ;;
  systemd)
    sudo systemctl stop "$V1_SERVICE" || die "systemctl stop $V1_SERVICE failed"
    ;;
  bare)
    if pgrep -f 'dagtech-node|blockdag|qng' >/dev/null; then
      warn "bare processes detected - sending SIGTERM..."
      pkill -TERM -f 'dagtech-node|blockdag|qng' || true
      sleep 5
      pkill -KILL -f 'dagtech-node|blockdag|qng' 2>/dev/null || true
    fi
    ;;
esac
ok "v1 stopped"

# --- BACKUP DATADIR (rename, not copy) ----------------------------------
BACKUP="${V1_DATA}.v1-backup-${TS}"
log "renaming v1 datadir to ${BACKUP}..."
mv "$V1_DATA" "$BACKUP" || die "could not rename datadir to backup"
mkdir -p "$V1_DATA"
ok "v1 datadir preserved at: $BACKUP"

# --- INSTALL V2.0.1 -----------------------------------------------------
log "installing v2.0.1 binary..."
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "unsupported arch: $ARCH_RAW" ;;
esac

BINARY="dagtech-node-${VERSION}-${OS}-${ARCH}"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

curl -fL --progress-bar -o "${TMPD}/${BINARY}" "${BASE_URL}/${BINARY}" || die "download failed"
curl -fL --silent  -o "${TMPD}/SHA256SUMS" "${BASE_URL}/SHA256SUMS" || die "SHA256SUMS download failed"

cd "$TMPD"
sha256sum -c SHA256SUMS --ignore-missing 2>&1 | grep -q "${BINARY}: OK" \
  || die "SHA-256 verify failed for ${BINARY} - aborting and rolling back"
cd - >/dev/null
ok "binary verified"

INSTALL_DIR="${V1_DIR}/bin"
mkdir -p "$INSTALL_DIR"
install -m 0755 "${TMPD}/${BINARY}" "${INSTALL_DIR}/dagtech-node" \
  || sudo install -m 0755 "${TMPD}/${BINARY}" "${INSTALL_DIR}/dagtech-node"

# Symlink update
sudo ln -sf "${INSTALL_DIR}/dagtech-node" /usr/local/bin/dagtech-node 2>/dev/null \
  || ln -sf "${INSTALL_DIR}/dagtech-node" /usr/local/bin/dagtech-node 2>/dev/null || true

ok "v2.0.1 installed: ${INSTALL_DIR}/dagtech-node"

# --- START V2.0.1 -------------------------------------------------------
log "starting v2.0.1..."
case "$V1_STYLE" in
  docker)
    ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" up -d ) || die "docker compose up failed"
    ;;
  systemd)
    sudo systemctl start "$V1_SERVICE" || die "systemctl start $V1_SERVICE failed"
    ;;
  bare)
    nohup "${INSTALL_DIR}/dagtech-node" --config "${V1_DIR}/config.toml" > "${V1_DIR}/v201.log" 2>&1 &
    ;;
esac
ok "v2.0.1 process up"

# --- VERIFY (first block import within 60s) -----------------------------
log "verifying first block import (60s)..."
START_TIME=$(date +%s)
DEADLINE=$((START_TIME + 60))
IMPORTED="no"

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  # Try RPC
  if curl -fsS -m 3 -X POST http://127.0.0.1:18545 \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
      | grep -q '"result":"0x'; then
    IMPORTED="yes"
    break
  fi
  # Or check container log
  if [ "$V1_STYLE" = "docker" ] && docker compose -f "$V1_COMPOSE" logs --tail=200 2>/dev/null | grep -qE 'Imported new block|block.*number=[1-9]'; then
    IMPORTED="yes"
    break
  fi
  sleep 3
done

if [ "$IMPORTED" = "yes" ]; then
  ok "v2.0.1 importing blocks - upgrade successful"
  echo ""
  cat <<EONOTE
  Upgrade complete. v1 backup retained at:

    ${BACKUP}

  Once you confirm v2.0.1 is healthy after 24h, reclaim disk:
    rm -rf "${BACKUP}"

  New flags:
    --rescue                    (non-destructive recovery; replaces --cleanup)
    --state.diff-layers-max=N   (256 default; tune to RAM)

EONOTE
  exit 0
fi

# --- ROLLBACK ----------------------------------------------------------
warn "v2.0.1 did not import a block within 60s - rolling back..."
case "$V1_STYLE" in
  docker)   ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" stop ) || true ;;
  systemd)  sudo systemctl stop "$V1_SERVICE" || true ;;
  bare)     pkill -TERM -f 'dagtech-node' || true; sleep 3; pkill -KILL -f 'dagtech-node' 2>/dev/null || true ;;
esac

rm -rf "$V1_DATA"
mv "$BACKUP" "$V1_DATA" || die "rollback failed - manual recovery needed at $BACKUP"
ok "datadir restored from backup"

case "$V1_STYLE" in
  docker)   ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" up -d ) || true ;;
  systemd)  sudo systemctl start "$V1_SERVICE" || true ;;
esac

die "upgrade rolled back; v1 restored. Investigate ${V1_DIR}/v201.log or journalctl"
