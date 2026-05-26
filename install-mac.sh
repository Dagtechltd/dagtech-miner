#!/usr/bin/env bash
# ============================================================================
# DagTech Miner - macOS Installer
# Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
# https://dagtech.network
#
# Usage: ./install-mac.sh
# ============================================================================
set -euo pipefail

DAGTECH_VERSION="2.1.0"
INSTALL_DIR="$HOME/.dagtech-miner"
CONFIG_FILE="$INSTALL_DIR/config.env"
BIN_DIR="$INSTALL_DIR/bin"
DASHBOARD_DIR="$INSTALL_DIR/dashboard"
LOG_DIR="$INSTALL_DIR/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo ""
    echo -e "${BLUE}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║                                          ║${NC}"
    echo -e "${BLUE}  ║   ${BOLD}${CYAN}DagTech Miner${NC}${BLUE}  v${DAGTECH_VERSION}               ║${NC}"
    echo -e "${BLUE}  ║   ${NC}dagtech.network - macOS${BLUE}                ║${NC}"
    echo -e "${BLUE}  ║                                          ║${NC}"
    echo -e "${BLUE}  ║   ${NC}By Dawie Nel / DagTech Ltd${BLUE}             ║${NC}"
    echo -e "${BLUE}  ║                                          ║${NC}"
    echo -e "${BLUE}  ╚══════════════════════════════════════════╝${NC}"
    echo ""
}

info()    { echo -e "${BLUE}[DagTech]${NC} $1"; }
success() { echo -e "${GREEN}[DagTech]${NC} $1"; }
warn()    { echo -e "${YELLOW}[DagTech]${NC} $1"; }
error()   { echo -e "${RED}[DagTech]${NC} $1"; }

check_macos() {
    info "Checking macOS..."
    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "This installer is for macOS only."
        error "For Linux use install.sh, for Windows use install.bat"
        exit 1
    fi
    local macos_ver
    macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    success "macOS $macos_ver detected"
}

check_architecture() {
    info "Checking CPU architecture..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            success "Architecture: Intel x86_64"
            ;;
        arm64)
            success "Architecture: Apple Silicon (M-series)"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
}

check_hardware() {
    info "Checking hardware..."
    local cores
    cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
    local ram_bytes
    ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    local ram_mb=$((ram_bytes / 1048576))
    local cpu_brand
    cpu_brand=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")

    echo ""
    echo -e "  ${BOLD}Hardware Summary:${NC}"
    echo -e "  CPU:     ${CYAN}$cpu_brand${NC}"
    echo -e "  Cores:   ${CYAN}$cores${NC}"
    echo -e "  RAM:     ${CYAN}${ram_mb} MB${NC}"
    echo ""

    if (( ram_mb < 512 )); then
        error "Insufficient RAM (${ram_mb}MB). Minimum: 512MB"
        exit 1
    fi

    success "Hardware check passed"
    # macOS doesn't have traditional GPU mining support via CUDA/ROCm
    GPU_AVAILABLE=0
    warn "Note: GPU mining requires NVIDIA CUDA (not available on macOS)"
    warn "CPU-only mode will be used"
}

install_dependencies() {
    info "Checking dependencies..."

    # Check for Xcode command line tools (includes gcc/clang)
    if ! xcode-select -p &>/dev/null; then
        info "Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        echo ""
        warn "Xcode CLT installation may open a dialog."
        warn "Please complete the installation and re-run this script."
        exit 0
    fi
    success "Xcode Command Line Tools found"

    # Check for OpenSSL via Homebrew (optional, we have built-in SHA256)
    if command -v brew &>/dev/null; then
        if brew list openssl &>/dev/null; then
            success "OpenSSL found via Homebrew (will use for acceleration)"
            export LDFLAGS="-L$(brew --prefix openssl)/lib"
            export CPPFLAGS="-I$(brew --prefix openssl)/include"
            HAS_OPENSSL=1
        else
            info "OpenSSL not found via Homebrew (using built-in SHA256)"
            HAS_OPENSSL=0
        fi
    else
        info "Homebrew not found (using built-in SHA256)"
        HAS_OPENSSL=0
    fi
}

configure_miner() {
    echo ""
    echo -e "${BOLD}  ─── Configuration ───${NC}"
    echo ""

    # Wallet
    local wallet_addr=""
    while true; do
        echo -ne "  ${CYAN}Enter your wallet address (0x...):${NC} "
        read -r wallet_addr
        if [[ "$wallet_addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            success "Wallet: $wallet_addr"
            break
        else
            warn "Invalid format. Must be 0x + 40 hex chars"
        fi
    done

    # Mode (CPU only on Mac)
    local mining_mode="cpu"
    info "Mining mode: CPU (macOS only supports CPU mining)"

    # Threads
    local total_cores
    total_cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
    local default_threads=$(( total_cores / 2 ))
    if (( default_threads < 1 )); then default_threads=1; fi

    echo ""
    echo -ne "  ${CYAN}CPU threads (1-$total_cores, default $default_threads):${NC} "
    read -r thread_input
    local thread_count=$default_threads
    if [[ -n "$thread_input" ]] && (( thread_input >= 1 && thread_input <= total_cores )); then
        thread_count=$thread_input
    fi
    success "Threads: $thread_count"

    # Pool
    echo ""
    local pool_addr="excalibur.dagtech.network"
    local pool_port=3335
    echo -ne "  ${CYAN}Pool address (default: $pool_addr):${NC} "
    read -r pool_input
    if [[ -n "$pool_input" ]]; then pool_addr="$pool_input"; fi
    echo -ne "  ${CYAN}Pool port (default: $pool_port):${NC} "
    read -r port_input
    if [[ -n "$port_input" ]]; then pool_port="$port_input"; fi
    success "Pool: $pool_addr:$pool_port"

    # Worker
    echo ""
    local worker="dagtech"
    echo -ne "  ${CYAN}Worker name (default: dagtech):${NC} "
    read -r worker_input
    if [[ -n "$worker_input" ]]; then worker="$worker_input"; fi

    # Save config
    mkdir -p "$INSTALL_DIR"
    cat > "$CONFIG_FILE" <<DAGTECH_CONFIG
# DagTech Miner Configuration - macOS
# Generated by DagTech Installer v${DAGTECH_VERSION}
WALLET=${wallet_addr}
POOL_HOST=${pool_addr}
POOL_PORT=${pool_port}
MINING_MODE=${mining_mode}
THREADS=${thread_count}
WORKER_NAME=${worker}
LOW_PRIORITY=0
METRICS_PORT=8880
DAGTECH_CONFIG

    success "Config saved"
}

build_miner() {
    info "Building DagTech Miner..."
    mkdir -p "$BIN_DIR" "$LOG_DIR" "$DASHBOARD_DIR"

    local src_dir
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src"

    # If source not found locally (standalone download), fetch from GitHub
    if [[ ! -f "$src_dir/dagtech_miner.c" ]]; then
        info "Downloading source from GitHub..."
        local tmp_src="/tmp/dagtech-miner-src"
        rm -rf "$tmp_src"
        if ! git clone --depth 1 https://github.com/Dagtechltd/dagtech-miner.git "$tmp_src" 2>/dev/null; then
            # Fallback: direct download if git clone fails
            info "Git clone failed, trying direct download..."
            mkdir -p "$tmp_src/src"
            curl -fsSL "https://raw.githubusercontent.com/Dagtechltd/dagtech-miner/main/src/dagtech_miner.c" \
                -o "$tmp_src/src/dagtech_miner.c" || true
        fi
        src_dir="$tmp_src/src"
    fi

    if [[ ! -f "$src_dir/dagtech_miner.c" ]]; then
        error "Source not found: $src_dir/dagtech_miner.c"
        exit 1
    fi

    local cc="clang"
    local cflags="-O2 -Wall"
    local ldflags="-lpthread"

    # Use OpenSSL if available
    if [[ "${HAS_OPENSSL:-0}" == "1" ]]; then
        cflags="$cflags -DUSE_OPENSSL $CPPFLAGS"
        ldflags="$ldflags $LDFLAGS -lssl -lcrypto"
    fi

    info "Compiling with: $cc $cflags"
    if ! $cc $cflags -o "$BIN_DIR/dagtech-miner" "$src_dir/dagtech_miner.c" $ldflags 2>&1; then
        error "Build failed!"
        exit 1
    fi

    chmod +x "$BIN_DIR/dagtech-miner"
    success "Build complete"

    # Self-test
    if "$BIN_DIR/dagtech-miner" --help >/dev/null 2>&1; then
        success "Self-test passed"
    else
        error "Self-test failed"
        exit 1
    fi
}

install_dashboard() {
    info "Installing dashboard..."
    local dash_src
    dash_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dashboard"
    if [[ -f "$dash_src/index.html" ]]; then
        cp "$dash_src/index.html" "$DASHBOARD_DIR/"
        [[ -f "$dash_src/dashboard_server.py" ]] && cp "$dash_src/dashboard_server.py" "$DASHBOARD_DIR/"
        success "Dashboard installed"
    fi
}

create_launcher() {
    info "Creating launcher scripts..."

    cat > "$BIN_DIR/dagtech-start" <<'LAUNCHER'
#!/usr/bin/env bash
# DagTech Miner Launcher - macOS
# dagtech.network - Dawie Nel / DagTech Ltd
INSTALL_DIR="$HOME/.dagtech-miner"
source "$INSTALL_DIR/config.env"
BIN="$INSTALL_DIR/bin/dagtech-miner"
DASHBOARD="$INSTALL_DIR/dashboard"

# Determine connection target — use proxy if installed (macOS 26+)
CONNECT_HOST="$POOL_HOST"
CONNECT_PORT="$POOL_PORT"
if [[ -n "${PROXY_PORT:-}" ]] && [[ -x "$INSTALL_DIR/bin/dagtech-proxy" ]]; then
    # Start proxy if not already running
    if ! pgrep -f dagtech-proxy >/dev/null 2>&1; then
        "$INSTALL_DIR/bin/dagtech-proxy" &
        PROXY_PID=$!
        sleep 1
        echo "[DagTech] LAN proxy started (localhost:$PROXY_PORT -> $POOL_HOST:$POOL_PORT)"
    fi
    CONNECT_HOST="127.0.0.1"
    CONNECT_PORT="$PROXY_PORT"
fi

echo ""
echo "  DagTech Miner - dagtech.network"
echo "  Pool: $CONNECT_HOST:$CONNECT_PORT"
echo "  Wallet: $WALLET"
echo "  Threads: $THREADS"
echo ""

# Dashboard (use dashboard_server.py for /api/metrics proxy)
if [[ -f "$DASHBOARD/dashboard_server.py" ]] && command -v python3 &>/dev/null; then
    python3 "$DASHBOARD/dashboard_server.py" 8881 $METRICS_PORT &>/dev/null &
    DASH_PID=$!
    trap "kill $DASH_PID 2>/dev/null; kill ${PROXY_PID:-0} 2>/dev/null" EXIT
    echo "[DagTech] Dashboard: http://localhost:8881"
elif [[ -f "$DASHBOARD/index.html" ]] && command -v python3 &>/dev/null; then
    cd "$DASHBOARD" && python3 -m http.server 8881 --bind 127.0.0.1 &>/dev/null &
    DASH_PID=$!
    trap "kill $DASH_PID 2>/dev/null; kill ${PROXY_PID:-0} 2>/dev/null" EXIT
    echo "[DagTech] Dashboard: http://localhost:8881 (static mode)"
fi

ARGS="--wallet $WALLET --host $CONNECT_HOST --port $CONNECT_PORT --threads $THREADS --worker $WORKER_NAME --metrics-port $METRICS_PORT"
exec $BIN $ARGS
LAUNCHER
    chmod +x "$BIN_DIR/dagtech-start"

    cat > "$BIN_DIR/dagtech-stop" <<'STOP'
#!/usr/bin/env bash
pkill -f dagtech-miner 2>/dev/null && echo "[DagTech] Stopped" || echo "[DagTech] Not running"
STOP
    chmod +x "$BIN_DIR/dagtech-stop"

    cat > "$BIN_DIR/dagtech-status" <<'STATUS'
#!/usr/bin/env bash
source "$HOME/.dagtech-miner/config.env" 2>/dev/null
if pgrep -f dagtech-miner >/dev/null 2>&1; then
    echo "[DagTech] RUNNING"
    curl -s "http://127.0.0.1:${METRICS_PORT:-8880}/metrics" 2>/dev/null | python3 -m json.tool 2>/dev/null
else
    echo "[DagTech] STOPPED"
fi
STATUS
    chmod +x "$BIN_DIR/dagtech-status"
    success "Launchers created"
}

setup_path() {
    info "Setting up PATH..."
    local shell_rc="$HOME/.zshrc"
    [[ ! -f "$shell_rc" ]] && shell_rc="$HOME/.bash_profile"
    local path_line='export PATH="$HOME/.dagtech-miner/bin:$PATH"'
    if ! grep -qF ".dagtech-miner/bin" "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# DagTech Miner" >> "$shell_rc"
        echo "$path_line" >> "$shell_rc"
        success "Added to PATH in $shell_rc"
    fi
    export PATH="$HOME/.dagtech-miner/bin:$PATH"
}

install_lan_proxy() {
    # macOS 26.5+ blocks ad-hoc signed binaries from making LAN connections
    # when running from launchd (Local Network Privacy). Python (/usr/bin/python3)
    # is Apple-signed and exempt. This proxy listens on localhost and forwards
    # traffic to the pool on the LAN, letting the miner connect via 127.0.0.1.
    local macos_ver
    macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "0")
    local major="${macos_ver%%.*}"
    if (( major < 26 )); then return 0; fi

    info "macOS $macos_ver detected — installing LAN proxy for launchd compatibility..."

    local proxy_port=3336
    cat > "${BIN_DIR}/dagtech-proxy" <<'PROXY_SCRIPT'
#!/usr/bin/env python3
"""DagTech TCP Proxy - localhost -> pool LAN address.
Required on macOS 26.5+ where ad-hoc signed binaries cannot connect
to LAN hosts when running from launchd (Local Network Privacy)."""
import socket, threading, signal, sys, os, time

# Read config
config = {}
config_path = os.path.expanduser("~/.dagtech-miner/config.env")
if os.path.exists(config_path):
    with open(config_path) as f:
        for line in f:
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                config[k.strip()] = v.strip().strip('"').strip("'")

POOL_HOST = config.get("POOL_HOST", "excalibur.dagtech.network")
POOL_PORT = int(config.get("POOL_PORT", "3335"))
LOCAL_PORT = int(config.get("PROXY_PORT", "3336"))
LOG_FILE = os.path.expanduser("~/.dagtech-miner/logs/proxy.log")

running = True
def handle_signal(s, f):
    global running; running = False
signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg + "\n")
    except: pass

def forward(src, dst, name):
    try:
        while running:
            data = src.recv(4096)
            if not data: break
            dst.sendall(data)
    except: pass
    try: src.close()
    except: pass
    try: dst.close()
    except: pass

def handle_client(client):
    try:
        pool = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        pool.settimeout(10)
        pool.connect((POOL_HOST, POOL_PORT))
        log("Connected to pool " + POOL_HOST + ":" + str(POOL_PORT))
        t1 = threading.Thread(target=forward, args=(client, pool, "c2p"), daemon=True)
        t2 = threading.Thread(target=forward, args=(pool, client, "p2c"), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
    except Exception as e:
        log("Pool connect error: " + str(e))
        client.close()

log("Proxy starting")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", LOCAL_PORT))
srv.listen(5)
srv.settimeout(2)
log("Listening on 127.0.0.1:" + str(LOCAL_PORT) + " -> " + POOL_HOST + ":" + str(POOL_PORT))
while running:
    try:
        client, addr = srv.accept()
        log("Client connected from " + str(addr))
        threading.Thread(target=handle_client, args=(client,), daemon=True).start()
    except socket.timeout: continue
    except Exception as e:
        log("Accept error: " + str(e)); break
srv.close()
log("Proxy stopped")
PROXY_SCRIPT
    chmod +x "${BIN_DIR}/dagtech-proxy"

    # Add PROXY_PORT to config if not present
    if ! grep -q "PROXY_PORT" "$CONFIG_FILE" 2>/dev/null; then
        echo "PROXY_PORT=$proxy_port" >> "$CONFIG_FILE"
    fi

    # Install proxy launchd service
    local proxy_plist="$HOME/Library/LaunchAgents/network.dagtech.proxy.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$proxy_plist" <<PROXYPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>network.dagtech.proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${BIN_DIR}/dagtech-proxy</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>Nice</key>
    <integer>19</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/proxy-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/proxy-stderr.log</string>
</dict>
</plist>
PROXYPLIST
    launchctl load "$proxy_plist" 2>/dev/null
    success "LAN proxy installed (localhost:$proxy_port -> pool)"
    # Export flag so create_launchd_service uses proxy
    USING_PROXY=true
    PROXY_PORT=$proxy_port
}

create_launchd_service() {
    echo ""
    echo -ne "  ${CYAN}Install as launchd service (auto-start on login)? (y/N):${NC} "
    read -r svc_input
    if [[ ! "$svc_input" =~ ^[Yy] ]]; then return; fi

    source "$CONFIG_FILE"
    local plist="$HOME/Library/LaunchAgents/network.dagtech.miner.plist"
    mkdir -p "$HOME/Library/LaunchAgents"

    # On macOS 26.5+, the proxy is installed and miner connects via localhost
    local connect_host="${POOL_HOST}"
    local connect_port="${POOL_PORT}"
    if [[ "${USING_PROXY:-false}" == "true" ]]; then
        connect_host="127.0.0.1"
        connect_port="${PROXY_PORT:-3336}"
        info "Using LAN proxy: miner -> localhost:${connect_port} -> ${POOL_HOST}:${POOL_PORT}"
    fi

    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>network.dagtech.miner</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DIR}/dagtech-miner</string>
        <string>--wallet</string>
        <string>${WALLET}</string>
        <string>--host</string>
        <string>${connect_host}</string>
        <string>--port</string>
        <string>${connect_port}</string>
        <string>--threads</string>
        <string>${THREADS}</string>
        <string>--worker</string>
        <string>${WORKER_NAME}</string>
        <string>--metrics-port</string>
        <string>${METRICS_PORT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>Nice</key>
    <integer>19</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/miner.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/miner-error.log</string>
</dict>
</plist>
PLIST

    launchctl load "$plist" 2>/dev/null
    success "LaunchAgent installed"
    info "Start: launchctl start network.dagtech.miner"
    info "Stop:  launchctl stop network.dagtech.miner"
}

print_summary() {
    echo ""
    echo -e "${GREEN}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}  ║   ${BOLD}Installation Complete!${NC}${GREEN}                 ║${NC}"
    echo -e "${GREEN}  ╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Quick Start:${NC}"
    echo -e "    ${CYAN}dagtech-start${NC}    Start mining"
    echo -e "    ${CYAN}dagtech-stop${NC}     Stop mining"
    echo -e "    ${CYAN}dagtech-status${NC}   Check status"
    echo ""
    echo -e "  ${BOLD}Dashboard:${NC}  http://localhost:8881"
    echo -e "  ${BOLD}Config:${NC}     $CONFIG_FILE"
    echo ""
    echo -e "  ${BLUE}DagTech Miner v${DAGTECH_VERSION} - macOS${NC}"
    echo -e "  ${BLUE}By Dawie Nel / DagTech Ltd${NC}"
    echo ""
}

main() {
    print_banner
    check_macos
    check_architecture
    check_hardware
    install_dependencies
    configure_miner
    build_miner
    install_dashboard
    create_launcher
    setup_path
    install_lan_proxy
    create_launchd_service
    print_summary

    # Ask to start mining now
    echo ""
    echo -n "  Start mining now? (Y/n): "
    read -r start_input
    if [[ "$start_input" =~ ^[Nn] ]]; then
        echo ""
        echo "  To start mining later, run: dagtech-start"
        echo ""
    else
        echo ""
        echo "[DagTech] Starting miner..."
        exec "$BIN_DIR/dagtech-start"
    fi
}

main "$@"
