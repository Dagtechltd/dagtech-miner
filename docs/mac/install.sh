#!/bin/bash
# DagTech Mac Miner — one-line installer
# Usage: curl -fsSL https://miner.dagtech.network/mac/install.sh | bash
# Designed for FRESH macOS arm64 (M1/M2/M3/M4) — installs every prereq itself.
# SPDX-License-Identifier: LicenseRef-DagTech-Proprietary
# Copyright (c) 2026 DagTech Ltd. All rights reserved.

set -euo pipefail
IFS=$'\n\t'

# ============================================================
# CONFIG
# ============================================================
INSTALL_DIR="$HOME/.dagtech-miner"
BIN_NAME="bdag-mac-miner"
BIN_URL_PRIMARY="https://miner.dagtech.network/mac/dagtech-mac-miner-cpu-arm64-v2.1.0"
BIN_URL_FALLBACK="https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/docs/mac/dagtech-mac-miner-cpu-arm64-v2.1.0"
BIN_SHA256="c9222f7e022ab06c17d785ca44d737bd7580391c95e76ee5748ef06a71c202bf"
DEFAULT_POOL_HOST="excalibur.dagtech.network"
DEFAULT_POOL_PORT="3335"
DASHBOARD_PORT="8881"
VERSION="0.1.0"
PLIST_LABEL="network.dagtech.miner"

# DagTech brand
NAVY=$(printf '\033[38;5;17m')
BLUE=$(printf '\033[38;5;39m')
CYAN=$(printf '\033[38;5;87m')
MUTE=$(printf '\033[38;5;245m')
WARN=$(printf '\033[38;5;220m')
ERR=$(printf '\033[38;5;196m')
OK=$(printf '\033[38;5;46m')
BOLD=$(printf '\033[1m')
RESET=$(printf '\033[0m')

banner() {
  cat << EOF

  ${BLUE}${BOLD}DagTech Mac Miner${RESET}  ${MUTE}v${VERSION}${RESET}
  ${MUTE}BlockDAG CPU mining for Apple Silicon${RESET}
  ${MUTE}https://miner.dagtech.network${RESET}

EOF
}

say()    { echo "  ${1}"; }
heading() { echo; echo "${BOLD}${BLUE}▸ $1${RESET}"; }
ok()     { echo "  ${OK}✓${RESET} $1"; }
warn()   { echo "  ${WARN}!${RESET} $1"; }
fail()   { echo "  ${ERR}✗ $1${RESET}"; exit 1; }
ask()    { local prompt="$1"; local default="${2:-}"; local var
  # Read from /dev/tty when available (curl|bash case), fall back to stdin (CI / piped tests)
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    if [ -n "$default" ]; then
      read -r -p "    $prompt [${MUTE}${default}${RESET}]: " var </dev/tty 2>/dev/tty
    else
      read -r -p "    $prompt: " var </dev/tty 2>/dev/tty
    fi
  else
    if [ -n "$default" ]; then
      read -r -p "    $prompt [${default}]: " var || var=""
    else
      read -r -p "    $prompt: " var || var=""
    fi
  fi
  echo "${var:-$default}"
}

banner

# ============================================================
# Phase 0 — sanity check the host
# ============================================================
heading "Checking your Mac"

OS=$(uname -s)
ARCH=$(uname -m)
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "?")

[ "$OS" = "Darwin" ] || fail "This installer is for macOS only (detected $OS)"
ok "macOS $MACOS_VER"

if [ "$ARCH" != "arm64" ]; then
  warn "Detected $ARCH. v2.1.0 supports Apple Silicon (M1/M2/M3/M4) only."
  warn "Intel Mac support is on the roadmap. Aborting."
  exit 1
fi
ok "Apple Silicon ($ARCH)"

CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
P_CORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu)
E_CORES=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo 0)
ok "$CHIP ($P_CORES P-cores, $E_CORES E-cores)"

mkdir -p "$INSTALL_DIR"
ok "Install directory: $INSTALL_DIR"

# ============================================================
# Phase 1 — Xcode Command Line Tools
# ============================================================
heading "Xcode Command Line Tools"

if xcode-select -p >/dev/null 2>&1; then
  ok "Already installed at $(xcode-select -p)"
else
  warn "Not installed — triggering install dialog…"
  xcode-select --install >/dev/null 2>&1 || true
  echo
  echo "    ${WARN}A system dialog will pop up asking to install the Command Line Tools.${RESET}"
  echo "    ${WARN}Click 'Install', wait for it to finish (5–10 minutes), then re-run this script.${RESET}"
  echo
  exit 0
fi

# ============================================================
# Phase 2 — Homebrew
# ============================================================
heading "Homebrew"

BREW_BIN=""
for path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$path" ]; then BREW_BIN="$path"; break; fi
done

if [ -z "$BREW_BIN" ]; then
  warn "Homebrew not installed — installing now (this takes 1–3 minutes)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$path" ]; then BREW_BIN="$path"; break; fi
  done
  [ -n "$BREW_BIN" ] || fail "Homebrew install completed but brew not found"
  # Add to PATH for this session and future sessions
  eval "$($BREW_BIN shellenv)"
  if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
    echo 'eval "$('"$BREW_BIN"' shellenv)"' >> "$HOME/.zprofile"
  fi
  ok "Homebrew installed at $(dirname "$BREW_BIN")"
else
  ok "Already installed at $BREW_BIN"
  eval "$($BREW_BIN shellenv)" 2>/dev/null || true
fi

# ============================================================
# Phase 3 — Runtime dependencies
# ============================================================
heading "Runtime dependencies"

for pkg in openssl@3; do
  if "$BREW_BIN" --prefix "$pkg" >/dev/null 2>&1 && [ -d "$("$BREW_BIN" --prefix "$pkg")/lib" ]; then
    ok "$pkg already installed"
  else
    warn "$pkg not installed — installing…"
    "$BREW_BIN" install --quiet "$pkg" 2>&1 | tail -3
    ok "$pkg installed"
  fi
done

# ============================================================
# Phase 4 — Download miner binary
# ============================================================
heading "Mining engine"

BIN_PATH="$INSTALL_DIR/$BIN_NAME"

needs_download=true
if [ -f "$BIN_PATH" ]; then
  existing_sha=$(shasum -a 256 "$BIN_PATH" | awk '{print $1}')
  if [ "$existing_sha" = "$BIN_SHA256" ]; then
    ok "Already installed and verified (SHA matches)"
    needs_download=false
  else
    warn "Existing binary has different SHA — re-downloading"
  fi
fi

if $needs_download; then
  warn "Downloading v$VERSION (52 KB)…"
  if curl -fsSL --connect-timeout 10 -o "$BIN_PATH" "$BIN_URL_PRIMARY" 2>/dev/null; then
    ok "Downloaded from primary"
  elif curl -fsSL --connect-timeout 10 -o "$BIN_PATH" "$BIN_URL_FALLBACK" 2>/dev/null; then
    ok "Downloaded from GitHub fallback"
  else
    fail "Could not download binary. Check internet connection."
  fi

  actual_sha=$(shasum -a 256 "$BIN_PATH" | awk '{print $1}')
  if [ "$actual_sha" != "$BIN_SHA256" ]; then
    rm -f "$BIN_PATH"
    fail "SHA256 mismatch — expected $BIN_SHA256, got $actual_sha. Refusing to install."
  fi
  ok "SHA256 verified"

  chmod +x "$BIN_PATH"
  # Ad-hoc sign so Gatekeeper allows it
  codesign --force --sign - --timestamp=none "$BIN_PATH" 2>/dev/null
  ok "Signed for Gatekeeper"
fi

# ============================================================
# Phase 5 — Dashboard sidecar
# ============================================================
heading "Dashboard"

DASH_PY="$INSTALL_DIR/dashboard.py"
cat > "$DASH_PY" << 'PYEOF'
#!/usr/bin/env python3
#!/usr/bin/env python3
"""DagTech Mac Miner dashboard sidecar — parses miner.log + serves HTML."""
import json, os, re, sys, time, threading, http.server, socketserver, urllib.parse
from collections import deque

LOG_PATH = os.path.expanduser("~/.dagtech-miner/miner.log")
CONFIG_PATH = os.path.expanduser("~/.dagtech-miner/config.json")
PORT = 8881

stats = {
    "hashrate": 0.0,
    "total_hashes": 0,
    "submitted": 0,
    "accepted": 0,
    "rejected": 0,
    "current_job": "",
    "difficulty": 0.0,
    "shares_found": 0,
    "last_share_ts": 0,
    "started_ts": int(time.time()),
    "miner_running": False,
    "extranonce1": "",
    "pool_host": "",
    "wallet": "",
    "worker": "",
    "threads": 0,
    "version": "2.1.0",
}

# Read config if present
if os.path.exists(CONFIG_PATH):
    try:
        c = json.load(open(CONFIG_PATH))
        stats["pool_host"] = c.get("pool_host", "")
        stats["wallet"] = c.get("wallet", "")
        stats["worker"] = c.get("worker", "")
        stats["threads"] = c.get("threads", 0)
    except Exception: pass

# Tail miner.log
RE_STATS    = re.compile(r"\[STATS\]\s+([\d.]+)\s+H/s\s+\|\s+total=(\d+)\s+submitted=(\d+)\s+accepted=(\d+)")
RE_SHARE    = re.compile(r"\[THREAD \d+\] SHARE FOUND!")
RE_SUB      = re.compile(r"\[SUBSCRIBE\] extranonce1=(\w+)")
RE_AUTH     = re.compile(r"\[ACCEPTED\] total=(\d+)")
RE_DIFF     = re.compile(r"\[DIFFICULTY\] ([\d.]+)")
RE_JOB      = re.compile(r"\[NEW JOB\] id=([^\s]+) diff=([\d.]+)")
RE_REJECT   = re.compile(r"\[REJECT", re.I)

def tail_log():
    while True:
        if not os.path.exists(LOG_PATH):
            time.sleep(2); continue
        try:
            with open(LOG_PATH) as f:
                f.seek(0, 2)  # seek to end
                while True:
                    line = f.readline()
                    if not line: time.sleep(0.5); continue
                    stats["miner_running"] = True
                    m = RE_STATS.search(line)
                    if m:
                        stats["hashrate"] = float(m.group(1))
                        stats["total_hashes"] = int(m.group(2))
                        stats["submitted"] = int(m.group(3))
                        stats["accepted"] = int(m.group(4))
                    elif RE_SHARE.search(line):
                        stats["shares_found"] += 1
                        stats["last_share_ts"] = int(time.time())
                    elif (m := RE_SUB.search(line)): stats["extranonce1"] = m.group(1)
                    elif (m := RE_DIFF.search(line)): stats["difficulty"] = float(m.group(1))
                    elif (m := RE_JOB.search(line)):  stats["current_job"] = m.group(1)
                    elif RE_REJECT.search(line):     stats["rejected"] += 1
        except Exception:
            stats["miner_running"] = False
            time.sleep(2)

threading.Thread(target=tail_log, daemon=True).start()

HTML = """<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DagTech Mac Miner</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Space+Grotesk:wght@500;600;700&family=JetBrains+Mono:wght@500&display=swap" rel="stylesheet">
<style>
:root{--bg:#080b14;--fg:#f4f7fb;--primary:#1e90ff;--glow:#66b3ff;--accent:#0a4cbf;--card:#0a0f1a;--border:#171e2e;--muted:#607080;--good:#5bd17a;--warn:#ffb84d}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Inter',-apple-system,sans-serif;background:var(--bg);color:var(--fg);min-height:100vh}
body::before{content:'';position:fixed;inset:0;background:radial-gradient(ellipse 80% 50% at 50% 0%,hsl(210 100% 56%/0.08) 0%,transparent 60%);pointer-events:none;z-index:0}
.container{max-width:1100px;margin:0 auto;padding:2rem 1.5rem;position:relative;z-index:1}
header{display:flex;justify-content:space-between;align-items:center;margin-bottom:2rem}
h1{font-family:'Space Grotesk',sans-serif;font-size:1.6rem;font-weight:600;background:linear-gradient(135deg,var(--fg),var(--glow));-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
.version{color:var(--muted);font-size:.85rem;font-family:'JetBrains Mono',monospace}
.status{display:inline-flex;align-items:center;gap:.5rem;padding:.3rem .8rem;border-radius:99rem;font-size:.8rem;font-weight:500}
.status-good{background:hsl(140 60% 50%/0.12);border:1px solid hsl(140 60% 50%/0.3);color:var(--good)}
.status-bad{background:hsl(0 65% 50%/0.12);border:1px solid hsl(0 65% 50%/0.3);color:#ff6b6b}
.dot{width:8px;height:8px;border-radius:50%;background:currentColor;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.hero{background:linear-gradient(135deg,var(--card),#111b2e);border:1px solid var(--border);border-radius:1.2rem;padding:2rem;margin-bottom:1.5rem;box-shadow:0 0 40px hsl(210 100% 56%/0.06)}
.hero h2{font-family:'Space Grotesk',sans-serif;font-size:.9rem;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.5rem}
.hero .big{font-family:'Space Grotesk',sans-serif;font-size:3.5rem;font-weight:700;background:linear-gradient(135deg,var(--primary),var(--glow));-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;line-height:1}
.hero .unit{color:var(--muted);font-size:1.2rem;font-family:'JetBrains Mono',monospace;margin-left:.4rem}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:1rem;margin-bottom:1.5rem}
.stat{background:var(--card);border:1px solid var(--border);border-radius:.8rem;padding:1.2rem}
.stat .label{color:var(--muted);font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;margin-bottom:.4rem;font-weight:500}
.stat .value{font-family:'Space Grotesk',sans-serif;font-size:1.8rem;font-weight:600}
.stat .mono{font-family:'JetBrains Mono',monospace;font-size:1.1rem;color:var(--glow)}
.config-card{background:var(--card);border:1px solid var(--border);border-radius:.8rem;padding:1.3rem;margin-bottom:1rem}
.config-card h3{font-family:'Space Grotesk',sans-serif;font-size:1rem;margin-bottom:.8rem;color:var(--glow)}
.config-row{display:flex;justify-content:space-between;padding:.4rem 0;border-bottom:1px solid var(--border);font-size:.9rem}
.config-row:last-child{border-bottom:none}
.config-row .k{color:var(--muted)}
.config-row .v{font-family:'JetBrains Mono',monospace;font-size:.85rem}
footer{text-align:center;color:var(--muted);font-size:.8rem;margin-top:2rem;padding:1rem}
footer a{color:var(--primary);text-decoration:none}
.accepted{color:var(--good)}
.rejected{color:#ff6b6b}
</style></head>
<body><div class="container">
  <header>
    <div>
      <h1>DagTech Mac Miner</h1>
      <div class="version">v__VERSION__ &middot; bdag-mac-miner</div>
    </div>
    <div id="status" class="status status-bad"><span class="dot"></span><span id="status-text">connecting…</span></div>
  </header>

  <div class="hero">
    <h2>Hashrate</h2>
    <div><span id="hashrate" class="big">0.00</span><span class="unit">KH/s</span></div>
  </div>

  <div class="grid">
    <div class="stat"><div class="label">Total Hashes</div><div id="hashes" class="value">0</div></div>
    <div class="stat"><div class="label">Shares Found</div><div id="found" class="value">0</div></div>
    <div class="stat"><div class="label">Submitted</div><div id="submitted" class="value">0</div></div>
    <div class="stat"><div class="label">Accepted</div><div id="accepted" class="value accepted">0</div></div>
  </div>

  <div class="grid">
    <div class="stat"><div class="label">Current Difficulty</div><div id="diff" class="mono">—</div></div>
    <div class="stat"><div class="label">Current Job</div><div id="job" class="mono">—</div></div>
    <div class="stat"><div class="label">Uptime</div><div id="uptime" class="mono">—</div></div>
    <div class="stat"><div class="label">Extranonce1</div><div id="enonce" class="mono">—</div></div>
  </div>

  <div class="config-card">
    <h3>Configuration</h3>
    <div class="config-row"><span class="k">Pool</span><span class="v" id="pool">—</span></div>
    <div class="config-row"><span class="k">Wallet</span><span class="v" id="wallet">—</span></div>
    <div class="config-row"><span class="k">Worker</span><span class="v" id="worker">—</span></div>
    <div class="config-row"><span class="k">Threads</span><span class="v" id="threads">—</span></div>
  </div>

  <footer>
    DagTech Ltd &middot; <a href="https://miner.dagtech.network">miner.dagtech.network</a> &middot;
    <code>launchctl stop network.dagtech.miner</code> to stop
  </footer>
</div>
<script>
function fmt(n){return n.toLocaleString('en-US',{maximumFractionDigits:0})}
function fmtKH(h){return (h/1000).toFixed(2)}
function fmtTime(secs){
  const d = Math.floor(secs/86400), h = Math.floor((secs%86400)/3600);
  const m = Math.floor((secs%3600)/60), s = Math.floor(secs%60);
  if(d) return `${d}d ${h}h ${m}m`;
  if(h) return `${h}h ${m}m ${s}s`;
  return `${m}m ${s}s`;
}
function shortWallet(w){return w.length>20 ? w.slice(0,8)+'…'+w.slice(-6) : w}
async function tick(){
  try{
    const r = await fetch('/api/stats');
    const s = await r.json();
    document.getElementById('hashrate').textContent = fmtKH(s.hashrate);
    document.getElementById('hashes').textContent = fmt(s.total_hashes);
    document.getElementById('found').textContent = fmt(s.shares_found);
    document.getElementById('submitted').textContent = fmt(s.submitted);
    document.getElementById('accepted').textContent = fmt(s.accepted);
    document.getElementById('diff').textContent = s.difficulty.toFixed(4);
    document.getElementById('job').textContent = s.current_job.slice(0,24) || '—';
    document.getElementById('enonce').textContent = s.extranonce1 || '—';
    document.getElementById('uptime').textContent = fmtTime(Date.now()/1000 - s.started_ts);
    document.getElementById('pool').textContent = s.pool_host || '—';
    document.getElementById('wallet').textContent = shortWallet(s.wallet) || '—';
    document.getElementById('worker').textContent = s.worker || '—';
    document.getElementById('threads').textContent = s.threads || '—';
    const ind = document.getElementById('status');
    const txt = document.getElementById('status-text');
    if(s.miner_running){
      ind.className = 'status status-good';
      txt.textContent = 'mining';
    } else {
      ind.className = 'status status-bad';
      txt.textContent = 'offline';
    }
  }catch(e){
    document.getElementById('status').className = 'status status-bad';
    document.getElementById('status-text').textContent = 'sidecar down';
  }
}
tick(); setInterval(tick, 2000);
</script>
</body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **k): pass
    def do_GET(self):
        if self.path == "/api/stats":
            self.send_response(200); self.send_header("Content-Type","application/json")
            self.end_headers(); self.wfile.write(json.dumps(stats).encode())
        elif self.path in ("/","/index.html"):
            html = HTML.replace("__VERSION__", stats["version"])
            self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8")
            self.end_headers(); self.wfile.write(html.encode())
        else:
            self.send_response(404); self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), H) as s:
    print(f"DagTech dashboard on http://127.0.0.1:{PORT}")
    s.serve_forever()
PYEOF
chmod +x "$DASH_PY"
ok "Dashboard sidecar staged"

# ============================================================
# Phase 6 — User configuration prompts
# ============================================================
heading "Configuration"

EXISTING_WALLET=""
EXISTING_WORKER=""
EXISTING_THREADS=""
if [ -f "$INSTALL_DIR/config.json" ]; then
  EXISTING_WALLET=$(python3 -c "import json;print(json.load(open('$INSTALL_DIR/config.json')).get('wallet',''))" 2>/dev/null || echo "")
  EXISTING_WORKER=$(python3 -c "import json;print(json.load(open('$INSTALL_DIR/config.json')).get('worker',''))" 2>/dev/null || echo "")
  EXISTING_THREADS=$(python3 -c "import json;print(json.load(open('$INSTALL_DIR/config.json')).get('threads',''))" 2>/dev/null || echo "")
  warn "Found existing config — press Enter to keep current values."
fi

# Env-var overrides (for unattended install): DAGTECH_WALLET / WORKER / THREADS / POOL_HOST / POOL_PORT
if [ -n "${DAGTECH_WALLET:-}" ]; then
  WALLET="$DAGTECH_WALLET"
  if ! [[ "$WALLET" =~ ^0x[a-fA-F0-9]{40}$ ]]; then fail "DAGTECH_WALLET is not a valid 0x address: $WALLET"; fi
  ok "Wallet: $WALLET (from env)"
else
  MAX_TRIES=5; tries=0
  while :; do
    WALLET=$(ask "Your BlockDAG wallet address (0x…)" "$EXISTING_WALLET")
    if [[ "$WALLET" =~ ^0x[a-fA-F0-9]{40}$ ]]; then break; fi
    tries=$((tries+1))
    echo "    ${ERR}Invalid — must be 0x + 40 hex characters.${RESET}"
    if [ $tries -ge $MAX_TRIES ]; then fail "Too many invalid attempts. Set DAGTECH_WALLET env var to skip prompts."; fi
  done
fi

DEFAULT_WORKER=$(hostname -s | tr -d '.' | tr '[:upper:]' '[:lower:]')
WORKER="${DAGTECH_WORKER:-$(ask "Worker name (shown on the pool)" "${EXISTING_WORKER:-$DEFAULT_WORKER}")}"
THREADS="${DAGTECH_THREADS:-$(ask "Number of threads" "${EXISTING_THREADS:-$P_CORES}")}"
POOL_HOST="${DAGTECH_POOL_HOST:-$(ask "Pool host" "$DEFAULT_POOL_HOST")}"
POOL_PORT="${DAGTECH_POOL_PORT:-$(ask "Pool port" "$DEFAULT_POOL_PORT")}"

cat > "$INSTALL_DIR/config.json" << EOF
{
  "version": "$VERSION",
  "wallet": "$WALLET",
  "worker": "$WORKER",
  "threads": $THREADS,
  "pool_host": "$POOL_HOST",
  "pool_port": $POOL_PORT
}
EOF
ok "Config written to $INSTALL_DIR/config.json"

# ============================================================
# Phase 7 — launchd auto-start service
# ============================================================
heading "Background service (launchd)"

PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN_PATH}</string>
    <string>--host</string><string>${POOL_HOST}</string>
    <string>--port</string><string>${POOL_PORT}</string>
    <string>--wallet</string><string>${WALLET}.${WORKER}</string>
    <string>--threads</string><string>${THREADS}</string>
    <string>--password</string><string>x</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>${INSTALL_DIR}/miner.log</string>
  <key>StandardErrorPath</key><string>${INSTALL_DIR}/miner.log</string>
  <key>ProcessType</key><string>Background</string>
  <key>Nice</key><integer>5</integer>
</dict>
</plist>
EOF
ok "launchd plist written"

PLIST_DASH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.dashboard.plist"
cat > "$PLIST_DASH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PLIST_LABEL}.dashboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${DASH_PY}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${INSTALL_DIR}/dashboard.log</string>
  <key>StandardErrorPath</key><string>${INSTALL_DIR}/dashboard.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
ok "dashboard plist written"

# Stop any existing instances first
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl unload "$PLIST_DASH" 2>/dev/null || true
> "$INSTALL_DIR/miner.log"
> "$INSTALL_DIR/dashboard.log"

launchctl load "$PLIST_PATH"
ok "Mining service started"

launchctl load "$PLIST_DASH"
ok "Dashboard service started"

# ============================================================
# Phase 8 — Verify + open browser
# ============================================================
heading "Verifying"

sleep 3

# Check miner pid
MINER_PID=$(launchctl list "$PLIST_LABEL" 2>/dev/null | awk '/"PID"/ {print $3}' | tr -d ';')
if [ -n "$MINER_PID" ] && [ "$MINER_PID" != "-" ]; then
  ok "Miner PID $MINER_PID running"
else
  warn "Miner not in launchctl list — check $INSTALL_DIR/miner.log"
fi

# Check dashboard port
if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${DASHBOARD_PORT}/api/stats" 2>/dev/null; then
  ok "Dashboard responding on port ${DASHBOARD_PORT}"
else
  warn "Dashboard not yet responding — give it a few more seconds"
fi

# Open browser
sleep 2
open "http://127.0.0.1:${DASHBOARD_PORT}" 2>/dev/null && ok "Dashboard opened in browser"

# ============================================================
# Done
# ============================================================
cat << EOF

  ${BOLD}${OK}✓ Installation complete${RESET}

  ${BOLD}Dashboard:${RESET}    http://127.0.0.1:${DASHBOARD_PORT}
  ${BOLD}Stop mining:${RESET}  launchctl unload "$PLIST_PATH"
  ${BOLD}Start mining:${RESET} launchctl load "$PLIST_PATH"
  ${BOLD}View log:${RESET}     tail -f $INSTALL_DIR/miner.log
  ${BOLD}Uninstall:${RESET}    curl -fsSL https://miner.dagtech.network/mac/uninstall.sh | bash

  ${MUTE}Mining to ${POOL_HOST}:${POOL_PORT} as ${WORKER}@${WALLET:0:8}…${WALLET: -6}${RESET}
  ${MUTE}Auto-starts on every login. Re-run this installer any time to reconfigure.${RESET}

EOF
