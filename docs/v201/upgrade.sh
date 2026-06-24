#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-DagTech-Proprietary
# Copyright (c) 2026 DagTech Ltd. All rights reserved.
# Product: DagTech BlockDAG Node
# Release: v2.0.1 (Clean-Room Corruption-Proof)
# Author : DagTech Build
# CONFIDENTIAL - DagTech IP
#
# Upgrade an existing v1 install to v2.0.1.
# DATA-SAFE: never touches your chain data directory. Binary swap only.
# Atomic + reversible. Pre-upgrade head block is recorded; v2 must advance past it.
# Usage: curl -fsSL https://miner.dagtech.network/v201/upgrade.sh | bash

set -euo pipefail

VERSION="v2.0.1"
BASE_URL="https://miner.dagtech.network/v201"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

BLUE='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { printf "${BLUE}[upgrade]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[ ok  ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
die()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; exit 1; }

cat <<'BANNER'
   DagTech BlockDAG Node - Upgrade  v1  ->  v2.0.1
   DATA-SAFE: chain directory will NOT be moved or wiped.
BANNER
echo ""

# --- DETECT EXISTING INSTALL --------------------------------------------
log "scanning for v1 install..."
V1_DIR=""; V1_DATA=""; V1_STYLE=""; V1_COMPOSE=""; V1_SERVICE=""
CANDIDATES=("/home/bdag/blockdag-release" "/opt/blockdag" "/opt/dagtech-node" "${HOME}/.dagtech-node")
for c in "${CANDIDATES[@]}"; do [ -d "$c" ] && V1_DIR="$c" && break; done
[ -n "$V1_DIR" ] || die "no v1 install found in any of: ${CANDIDATES[*]}"
ok "v1 install located: $V1_DIR"

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
  warn "run style: bare process"
fi

for d in "$V1_DIR/data" "$V1_DIR/datadir" "${HOME}/.dagtech-node/data" "/var/lib/dagtech-node"; do
  [ -d "$d" ] && V1_DATA="$d" && break
done
[ -n "$V1_DATA" ] || die "could not locate v1 data directory"
ok "v1 datadir: $V1_DATA   (THIS WILL NOT BE TOUCHED)"

# --- DETECT DOCKER UPGRADE STRATEGY -------------------------------------
# Two docker patterns exist in the wild:
#   A. compose pulls an image (image: dagtechnetwork/blockdag-node:vN)
#      -> binary swap on host does NOTHING; image must be retagged. Refuse.
#   B. compose runs a host binary (command: /opt/.../dagtech-node, volume mount)
#      -> binary swap works.
if [ "$V1_STYLE" = "docker" ]; then
  if grep -qE '^\s*image:\s*(dagtech|blockdag|qitmeer|qng)' "$V1_COMPOSE" \
     && ! grep -qE '(\./bin/|/usr/local/bin/)?dagtech-node' "$V1_COMPOSE"; then
    die "your docker compose pulls an image rather than running a host binary.
       Image-tag upgrade path ships in v2.0.2 (announced soon).
       For now: keep running v1 (your data is safe), or do a fresh-box install
       in a separate directory using: ${BASE_URL}/install.sh"
  fi
fi

# --- RECORD PRE-UPGRADE HEAD BLOCK --------------------------------------
log "recording pre-upgrade head block..."
PRE_HEAD=""
for port in 18545 8545 38131; do
  RESP="$(curl -fsS -m 3 -X POST "http://127.0.0.1:${port}" \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)"
  if [ -n "$RESP" ] && echo "$RESP" | grep -q '"result":"0x'; then
    HEX="$(echo "$RESP" | grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+')"
    PRE_HEAD="$((HEX))"
    ok "pre-upgrade head: block ${PRE_HEAD} (RPC port ${port})"
    break
  fi
done
[ -n "$PRE_HEAD" ] || warn "could not read pre-upgrade head via RPC; will verify via log instead"

# --- STOP V1 ------------------------------------------------------------
log "stopping v1..."
case "$V1_STYLE" in
  docker)  ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" stop ) || die "docker compose stop failed" ;;
  systemd) sudo systemctl stop "$V1_SERVICE" || die "systemctl stop $V1_SERVICE failed" ;;
  bare)    pgrep -f 'dagtech-node|blockdag|qng' >/dev/null && { pkill -TERM -f 'dagtech-node|blockdag|qng' || true; sleep 5; pkill -KILL -f 'dagtech-node|blockdag|qng' 2>/dev/null || true; } ;;
esac
ok "v1 stopped"

# --- BACKUP V1 BINARY (NOT DATADIR) -------------------------------------
log "locating v1 binary..."
V1_BIN=""
for b in "$V1_DIR/bin/dagtech-node" "/usr/local/bin/dagtech-node" "/usr/local/bin/bdag" "$V1_DIR/dagtech-node" "$V1_DIR/bdag"; do
  if [ -e "$b" ]; then V1_BIN="$(readlink -f "$b" 2>/dev/null || echo "$b")"; break; fi
done
if [ -n "$V1_BIN" ] && [ -f "$V1_BIN" ]; then
  BIN_BACKUP="${V1_BIN}.v1-backup-${TS}"
  cp -a "$V1_BIN" "$BIN_BACKUP" || sudo cp -a "$V1_BIN" "$BIN_BACKUP" || die "could not back up v1 binary"
  ok "v1 binary backed up: $BIN_BACKUP"
else
  warn "no v1 binary on host filesystem (likely docker image-pull). Skipping binary backup."
  V1_BIN=""
fi

# --- DOWNLOAD + VERIFY V2 BINARY ----------------------------------------
log "downloading v2.0.1 binary..."
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64|amd64)   ARCH="amd64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac
BINARY="dagtech-node-${VERSION}-${OS}-${ARCH}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
curl -fL --progress-bar -o "${TMPD}/${BINARY}" "${BASE_URL}/${BINARY}" || die "download failed"
curl -fL --silent       -o "${TMPD}/SHA256SUMS" "${BASE_URL}/SHA256SUMS" || die "SHA256SUMS download failed"
( cd "$TMPD" && sha256sum -c SHA256SUMS --ignore-missing 2>&1 | grep -q "${BINARY}: OK" ) \
  || die "SHA-256 verify failed; aborting (v1 still installed, data intact)"
ok "binary verified ($BINARY)"

# --- INSTALL V2 BINARY IN PLACE -----------------------------------------
if [ -n "$V1_BIN" ]; then
  install -m 0755 "${TMPD}/${BINARY}" "$V1_BIN" \
    || sudo install -m 0755 "${TMPD}/${BINARY}" "$V1_BIN" \
    || die "could not install v2 binary at $V1_BIN"
  ok "v2.0.1 installed at $V1_BIN"
else
  INSTALL_DIR="${V1_DIR}/bin"
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "${TMPD}/${BINARY}" "${INSTALL_DIR}/dagtech-node" || die "install failed"
  V1_BIN="${INSTALL_DIR}/dagtech-node"
  ok "v2.0.1 installed at $V1_BIN (host-binary mode)"
fi

# --- START V2 -----------------------------------------------------------
log "starting v2.0.1..."
case "$V1_STYLE" in
  docker)  ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" up -d ) || die "docker compose up failed" ;;
  systemd) sudo systemctl start "$V1_SERVICE" || die "systemctl start $V1_SERVICE failed" ;;
  bare)    nohup "$V1_BIN" --config "${V1_DIR}/config.toml" > "${V1_DIR}/v201.log" 2>&1 & ;;
esac
ok "v2.0.1 process up"

# --- VERIFY HEAD ADVANCES PAST PRE_HEAD (not fresh sync) ----------------
log "verifying head advances past pre-upgrade block ${PRE_HEAD:-unknown} (90s)..."
START_TIME=$(date +%s); DEADLINE=$((START_TIME + 90)); ADVANCED="no"; FRESH_SYNC="no"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  for port in 18545 8545 38131; do
    RESP="$(curl -fsS -m 3 -X POST "http://127.0.0.1:${port}" \
              -H 'Content-Type: application/json' \
              -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)"
    if [ -n "$RESP" ] && echo "$RESP" | grep -q '"result":"0x'; then
      HEX="$(echo "$RESP" | grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+')"
      NOW_HEAD="$((HEX))"
      if [ -n "$PRE_HEAD" ]; then
        if [ "$NOW_HEAD" -lt "$((PRE_HEAD - 1000))" ]; then
          FRESH_SYNC="yes"; break 2
        fi
        if [ "$NOW_HEAD" -gt "$PRE_HEAD" ]; then
          ADVANCED="yes"; ok "head advanced ${PRE_HEAD} -> ${NOW_HEAD}"; break 2
        fi
      else
        # no pre-head: any block import counts
        ADVANCED="yes"; ok "v2 importing blocks (head ${NOW_HEAD})"; break 2
      fi
      break
    fi
  done
  sleep 3
done

if [ "$FRESH_SYNC" = "yes" ]; then
  warn "DETECTED FRESH RESYNC (head ${NOW_HEAD} << pre-upgrade ${PRE_HEAD}). Rolling back."
elif [ "$ADVANCED" = "yes" ]; then
  cat <<EONOTE

  Upgrade complete. Your chain data was preserved in place.

  v1 binary backup (delete after 24h of healthy v2):
    ${BIN_BACKUP:-<none — docker image-pull mode>}

  New flags:
    --rescue                    non-destructive recovery (replaces --cleanup)
    --state.diff-layers-max=N   256 default; tune to RAM

EONOTE
  exit 0
else
  warn "v2.0.1 did not advance head within 90s - rolling back"
fi

# --- ROLLBACK -----------------------------------------------------------
case "$V1_STYLE" in
  docker)  ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" stop ) || true ;;
  systemd) sudo systemctl stop "$V1_SERVICE" || true ;;
  bare)    pkill -TERM -f 'dagtech-node' || true; sleep 3; pkill -KILL -f 'dagtech-node' 2>/dev/null || true ;;
esac
if [ -n "${BIN_BACKUP:-}" ] && [ -f "$BIN_BACKUP" ]; then
  install -m 0755 "$BIN_BACKUP" "$V1_BIN" || sudo install -m 0755 "$BIN_BACKUP" "$V1_BIN" || die "rollback failed; manual restore from $BIN_BACKUP"
  ok "v1 binary restored at $V1_BIN"
fi
case "$V1_STYLE" in
  docker)  ( cd "$V1_DIR" && docker compose -f "$V1_COMPOSE" up -d ) || true ;;
  systemd) sudo systemctl start "$V1_SERVICE" || true ;;
esac
die "upgrade rolled back; v1 restored (chain data was never touched)"
