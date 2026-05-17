#!/usr/bin/env bash
# ============================================================================
# DagTech Miner - Linux Installer
# Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
# https://dagtech.network
#
# One-command installer: curl -sSL https://get.dagtech.network | bash
# Or: ./install.sh
# ============================================================================
set -euo pipefail

DAGTECH_VERSION="1.0.0"
INSTALL_DIR="$HOME/.dagtech-miner"
CONFIG_FILE="$INSTALL_DIR/config.env"
BIN_DIR="$INSTALL_DIR/bin"
DASHBOARD_DIR="$INSTALL_DIR/dashboard"
LOG_DIR="$INSTALL_DIR/logs"
SERVICE_NAME="dagtech-miner"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# DagTech Branding
# ============================================================================
print_banner() {
    echo ""
    echo -e "${BLUE}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║                                          ║${NC}"
    echo -e "${BLUE}  ║   ${BOLD}${CYAN}DagTech Miner${NC}${BLUE}  v${DAGTECH_VERSION}               ║${NC}"
    echo -e "${BLUE}  ║   ${NC}dagtech.network${BLUE}                       ║${NC}"
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

# ============================================================================
# System Checks
# ============================================================================
check_os() {
    info "Checking operating system..."
    if [[ "$(uname -s)" != "Linux" ]]; then
        error "This installer is for Linux only."
        error "For Windows, use install.bat | For Mac, use install-mac.sh"
        exit 1
    fi
    success "Linux detected: $(uname -r)"
}

check_architecture() {
    info "Checking CPU architecture..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            success "Architecture: x86_64 (supported)"
            ;;
        aarch64|arm64)
            success "Architecture: ARM64 (supported)"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
}

check_cpu() {
    info "Checking CPU capabilities..."
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    local model
    model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
    local ram_mb
    ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo 0)

    echo ""
    echo -e "  ${BOLD}Hardware Summary:${NC}"
    echo -e "  CPU:     ${CYAN}$model${NC}"
    echo -e "  Cores:   ${CYAN}$cores${NC}"
    echo -e "  RAM:     ${CYAN}${ram_mb} MB${NC}"
    echo ""

    # CPU mining needs at least 2 cores and 512MB RAM
    if (( cores < 2 )); then
        warn "Low core count ($cores). CPU mining will be slow."
        warn "Minimum recommended: 4 cores"
    fi
    if (( ram_mb < 512 )); then
        error "Insufficient RAM (${ram_mb}MB). Minimum: 512MB"
        exit 1
    fi
    if (( ram_mb < 2048 )); then
        warn "Low RAM (${ram_mb}MB). Recommended: 2GB+"
    fi

    success "CPU check passed"
}

check_gpu() {
    info "Checking GPU availability..."
    local has_nvidia=0
    local has_amd=0
    local gpu_name=""

    # Check NVIDIA
    if command -v nvidia-smi &>/dev/null; then
        has_nvidia=1
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
        local vram
        vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown")
        echo -e "  GPU:     ${CYAN}$gpu_name${NC}"
        echo -e "  VRAM:    ${CYAN}$vram${NC}"
        success "NVIDIA GPU detected with CUDA support"
    fi

    # Check AMD
    if command -v rocm-smi &>/dev/null || lspci 2>/dev/null | grep -iq "amd.*vga\|radeon"; then
        has_amd=1
        gpu_name=$(lspci 2>/dev/null | grep -i "vga\|3d" | grep -i "amd\|radeon" | head -1 | sed 's/.*: //' || echo "AMD GPU")
        echo -e "  GPU:     ${CYAN}$gpu_name${NC}"
        if ! command -v rocm-smi &>/dev/null; then
            warn "AMD GPU found but ROCm drivers not installed"
            warn "GPU mining requires ROCm. Install from: https://rocm.docs.amd.com"
            has_amd=0
        else
            success "AMD GPU detected with ROCm support"
        fi
    fi

    if (( has_nvidia == 0 && has_amd == 0 )); then
        warn "No supported GPU detected. CPU-only mining available."
        echo ""
        GPU_AVAILABLE=0
    else
        GPU_AVAILABLE=1
    fi
}

# ============================================================================
# Dependency Installation
# ============================================================================
install_dependencies() {
    info "Installing build dependencies..."

    # Detect package manager
    local pkg_mgr=""
    if command -v apt-get &>/dev/null; then
        pkg_mgr="apt"
    elif command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    elif command -v yum &>/dev/null; then
        pkg_mgr="yum"
    elif command -v pacman &>/dev/null; then
        pkg_mgr="pacman"
    elif command -v zypper &>/dev/null; then
        pkg_mgr="zypper"
    else
        error "No supported package manager found"
        error "Please install manually: gcc, make, libssl-dev, git"
        exit 1
    fi

    info "Package manager: $pkg_mgr"

    local need_sudo=""
    if [[ $EUID -ne 0 ]]; then
        need_sudo="sudo"
    fi

    case "$pkg_mgr" in
        apt)
            $need_sudo apt-get update -qq
            $need_sudo apt-get install -y -qq build-essential libssl-dev git curl >/dev/null 2>&1
            ;;
        dnf|yum)
            $need_sudo $pkg_mgr install -y gcc make openssl-devel git curl >/dev/null 2>&1
            ;;
        pacman)
            $need_sudo pacman -Sy --noconfirm gcc make openssl git curl >/dev/null 2>&1
            ;;
        zypper)
            $need_sudo zypper install -y gcc make libopenssl-devel git curl >/dev/null 2>&1
            ;;
    esac

    # Verify critical dependencies
    for cmd in gcc make git; do
        if ! command -v $cmd &>/dev/null; then
            error "Failed to install $cmd"
            exit 1
        fi
    done

    success "All dependencies installed"
}

# ============================================================================
# Configuration Wizard
# ============================================================================
configure_miner() {
    echo ""
    echo -e "${BOLD}  ─── Configuration ───${NC}"
    echo ""

    # Wallet address
    local wallet_addr=""
    while true; do
        echo -ne "  ${CYAN}Enter your wallet address (0x...):${NC} "
        read -r wallet_addr
        if [[ "$wallet_addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            success "Wallet: $wallet_addr"
            break
        else
            warn "Invalid wallet format. Must be 0x followed by 40 hex characters."
            echo "  Example: 0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18"
        fi
    done

    # Mining mode
    echo ""
    echo -e "  ${BOLD}Select mining mode:${NC}"
    if (( GPU_AVAILABLE == 1 )); then
        echo -e "    ${CYAN}1)${NC} CPU only"
        echo -e "    ${CYAN}2)${NC} GPU only"
        echo -e "    ${CYAN}3)${NC} CPU + GPU (recommended)"
        echo ""
        echo -ne "  ${CYAN}Choice [1-3]:${NC} "
        read -r mode_choice
    else
        echo -e "    ${CYAN}1)${NC} CPU only (no GPU detected)"
        echo ""
        mode_choice="1"
        info "Auto-selected CPU-only mode (no GPU found)"
    fi

    local mining_mode="cpu"
    case "$mode_choice" in
        2) mining_mode="gpu" ;;
        3) mining_mode="both" ;;
        *) mining_mode="cpu" ;;
    esac
    success "Mining mode: $mining_mode"

    # Thread count (for CPU mining)
    local thread_count=0
    if [[ "$mining_mode" == "cpu" || "$mining_mode" == "both" ]]; then
        local total_cores
        total_cores=$(nproc 2>/dev/null || echo 4)
        local default_threads=$(( total_cores / 2 ))
        if (( default_threads < 1 )); then default_threads=1; fi

        echo ""
        echo -ne "  ${CYAN}CPU threads to use (1-$total_cores, default $default_threads):${NC} "
        read -r thread_input
        if [[ -z "$thread_input" ]]; then
            thread_count=$default_threads
        elif (( thread_input >= 1 && thread_input <= total_cores )); then
            thread_count=$thread_input
        else
            warn "Invalid thread count, using default: $default_threads"
            thread_count=$default_threads
        fi
        success "CPU threads: $thread_count"
    fi

    # Pool configuration
    echo ""
    local pool_addr="excalibur.dagtech.network"
    local pool_port=3334
    echo -ne "  ${CYAN}Pool address (default: $pool_addr):${NC} "
    read -r pool_input
    if [[ -n "$pool_input" ]]; then pool_addr="$pool_input"; fi

    echo -ne "  ${CYAN}Pool port (default: $pool_port):${NC} "
    read -r port_input
    if [[ -n "$port_input" ]]; then pool_port="$port_input"; fi
    success "Pool: $pool_addr:$pool_port"

    # Worker name
    echo ""
    local worker="dagtech"
    echo -ne "  ${CYAN}Worker name (default: dagtech):${NC} "
    read -r worker_input
    if [[ -n "$worker_input" ]]; then worker="$worker_input"; fi
    success "Worker: $worker"

    # Low priority option
    echo ""
    local low_priority=0
    echo -ne "  ${CYAN}Run at low CPU priority? (y/N):${NC} "
    read -r prio_input
    if [[ "$prio_input" =~ ^[Yy] ]]; then low_priority=1; fi

    # Save config
    mkdir -p "$INSTALL_DIR"
    cat > "$CONFIG_FILE" <<DAGTECH_CONFIG
# DagTech Miner Configuration
# Generated by DagTech Installer v${DAGTECH_VERSION}
# https://dagtech.network

WALLET=${wallet_addr}
POOL_HOST=${pool_addr}
POOL_PORT=${pool_port}
MINING_MODE=${mining_mode}
THREADS=${thread_count}
WORKER_NAME=${worker}
LOW_PRIORITY=${low_priority}
METRICS_PORT=8880
DAGTECH_CONFIG

    success "Configuration saved to $CONFIG_FILE"
}

# ============================================================================
# Build Miner
# ============================================================================
build_miner() {
    info "Building DagTech Miner..."

    mkdir -p "$BIN_DIR" "$LOG_DIR" "$DASHBOARD_DIR"

    # Determine source directory
    local src_dir
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src"

    if [[ ! -f "$src_dir/dagtech_miner.c" ]]; then
        error "Source file not found: $src_dir/dagtech_miner.c"
        error "Please run this installer from the dagtech-miner directory"
        exit 1
    fi

    # Detect optimal compiler flags
    local opt_flags="-O2"
    if gcc -march=native -E -x c /dev/null &>/dev/null 2>&1; then
        opt_flags="-O2 -march=native"
    fi

    info "Compiling with: gcc $opt_flags"
    gcc $opt_flags -Wall -Wextra -o "$BIN_DIR/dagtech-miner" \
        "$src_dir/dagtech_miner.c" \
        -lssl -lcrypto -lpthread -lm 2>&1

    if [[ $? -ne 0 ]]; then
        error "Build failed!"
        exit 1
    fi

    chmod +x "$BIN_DIR/dagtech-miner"
    success "Build complete: $BIN_DIR/dagtech-miner"

    # Quick self-test
    info "Running self-test..."
    if "$BIN_DIR/dagtech-miner" --help >/dev/null 2>&1; then
        success "Self-test passed"
    else
        error "Self-test failed - binary may be corrupted"
        exit 1
    fi
}

# ============================================================================
# Install Dashboard
# ============================================================================
install_dashboard() {
    info "Installing DagTech Dashboard..."

    local dash_src
    dash_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dashboard"

    if [[ -f "$dash_src/index.html" ]]; then
        cp "$dash_src/index.html" "$DASHBOARD_DIR/"
        success "Dashboard installed to $DASHBOARD_DIR"
    else
        warn "Dashboard files not found in source, generating..."
        # The dashboard HTML will be embedded in the release
    fi
}

# ============================================================================
# Create Launcher Script
# ============================================================================
create_launcher() {
    info "Creating launcher script..."

    cat > "$BIN_DIR/dagtech-start" <<'LAUNCHER_SCRIPT'
#!/usr/bin/env bash
# DagTech Miner Launcher - dagtech.network
# Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel

INSTALL_DIR="$HOME/.dagtech-miner"
CONFIG_FILE="$INSTALL_DIR/config.env"
BIN="$INSTALL_DIR/bin/dagtech-miner"
LOG_DIR="$INSTALL_DIR/logs"
DASHBOARD_DIR="$INSTALL_DIR/dashboard"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}[DagTech] Config not found. Run the installer first.${NC}"
    exit 1
fi

source "$CONFIG_FILE"

# Build command line
ARGS="--wallet $WALLET --pool $POOL_HOST --port $POOL_PORT --worker $WORKER_NAME"
ARGS="$ARGS --metrics-port $METRICS_PORT"

if [[ "$MINING_MODE" == "cpu" || "$MINING_MODE" == "both" ]]; then
    if (( THREADS > 0 )); then
        ARGS="$ARGS --threads $THREADS"
    fi
fi

if (( LOW_PRIORITY == 1 )); then
    ARGS="$ARGS --low-priority"
fi

echo ""
echo -e "${BLUE}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}  ║   ${BOLD}${CYAN}DagTech Miner${NC}${BLUE}                          ║${NC}"
echo -e "${BLUE}  ║   ${NC}dagtech.network${BLUE}                       ║${NC}"
echo -e "${BLUE}  ╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Wallet:${NC}  $WALLET"
echo -e "  ${BOLD}Pool:${NC}    $POOL_HOST:$POOL_PORT"
echo -e "  ${BOLD}Mode:${NC}    $MINING_MODE"
echo -e "  ${BOLD}Threads:${NC} $THREADS"
echo ""

# Start dashboard in background if available
if [[ -f "$DASHBOARD_DIR/index.html" ]] && command -v python3 &>/dev/null; then
    DASH_PORT=8881
    echo -e "${GREEN}[DagTech]${NC} Dashboard: http://localhost:$DASH_PORT"
    cd "$DASHBOARD_DIR" && python3 -m http.server $DASH_PORT --bind 127.0.0.1 &>/dev/null &
    DASH_PID=$!
    trap "kill $DASH_PID 2>/dev/null" EXIT
fi

# Log to file and stdout
LOGFILE="$LOG_DIR/miner-$(date +%Y%m%d-%H%M%S).log"
echo -e "${GREEN}[DagTech]${NC} Log: $LOGFILE"
echo ""

exec $BIN $ARGS 2>&1 | tee "$LOGFILE"
LAUNCHER_SCRIPT

    chmod +x "$BIN_DIR/dagtech-start"

    # Create stop script
    cat > "$BIN_DIR/dagtech-stop" <<'STOP_SCRIPT'
#!/usr/bin/env bash
# DagTech Miner Stop Script
pkill -f dagtech-miner 2>/dev/null && echo "[DagTech] Miner stopped" || echo "[DagTech] Miner not running"
STOP_SCRIPT
    chmod +x "$BIN_DIR/dagtech-stop"

    # Create status script
    cat > "$BIN_DIR/dagtech-status" <<'STATUS_SCRIPT'
#!/usr/bin/env bash
# DagTech Miner Status
source "$HOME/.dagtech-miner/config.env" 2>/dev/null
METRICS_PORT=${METRICS_PORT:-8880}

if pgrep -f dagtech-miner >/dev/null 2>&1; then
    echo -e "\033[0;32m[DagTech] Miner is RUNNING\033[0m"
    curl -s "http://127.0.0.1:$METRICS_PORT/metrics" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (metrics unavailable)"
else
    echo -e "\033[0;31m[DagTech] Miner is STOPPED\033[0m"
fi
STATUS_SCRIPT
    chmod +x "$BIN_DIR/dagtech-status"

    success "Launcher scripts created"
}

# ============================================================================
# Add to PATH
# ============================================================================
setup_path() {
    info "Setting up PATH..."

    local shell_rc=""
    if [[ -f "$HOME/.bashrc" ]]; then
        shell_rc="$HOME/.bashrc"
    elif [[ -f "$HOME/.zshrc" ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -f "$HOME/.profile" ]]; then
        shell_rc="$HOME/.profile"
    fi

    local path_line="export PATH=\"\$HOME/.dagtech-miner/bin:\$PATH\""

    if [[ -n "$shell_rc" ]]; then
        if ! grep -qF ".dagtech-miner/bin" "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "# DagTech Miner" >> "$shell_rc"
            echo "$path_line" >> "$shell_rc"
            success "Added to PATH in $shell_rc"
        else
            success "PATH already configured"
        fi
    fi

    export PATH="$HOME/.dagtech-miner/bin:$PATH"
}

# ============================================================================
# Create systemd service (optional)
# ============================================================================
setup_systemd_service() {
    echo ""
    echo -ne "  ${CYAN}Install as systemd service (auto-start on boot)? (y/N):${NC} "
    read -r svc_input
    if [[ ! "$svc_input" =~ ^[Yy] ]]; then return; fi

    source "$CONFIG_FILE"

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    local need_sudo=""
    if [[ $EUID -ne 0 ]]; then need_sudo="sudo"; fi

    $need_sudo tee "$service_file" > /dev/null <<SYSTEMD_SVC
[Unit]
Description=DagTech Miner - dagtech.network
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
ExecStart=$BIN_DIR/dagtech-miner --wallet $WALLET --pool $POOL_HOST --port $POOL_PORT --threads $THREADS --worker $WORKER_NAME --metrics-port $METRICS_PORT
Restart=always
RestartSec=30
Nice=19

[Install]
WantedBy=multi-user.target
SYSTEMD_SVC

    $need_sudo systemctl daemon-reload
    $need_sudo systemctl enable "$SERVICE_NAME"
    success "Systemd service installed: $SERVICE_NAME"
    info "Start with: sudo systemctl start $SERVICE_NAME"
    info "Logs with:  sudo journalctl -u $SERVICE_NAME -f"
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}  ║                                          ║${NC}"
    echo -e "${GREEN}  ║   ${BOLD}Installation Complete!${NC}${GREEN}                 ║${NC}"
    echo -e "${GREEN}  ║                                          ║${NC}"
    echo -e "${GREEN}  ╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Quick Start:${NC}"
    echo -e "    ${CYAN}dagtech-start${NC}    Start mining"
    echo -e "    ${CYAN}dagtech-stop${NC}     Stop mining"
    echo -e "    ${CYAN}dagtech-status${NC}   Check miner status"
    echo ""
    echo -e "  ${BOLD}Dashboard:${NC}"
    echo -e "    Open ${CYAN}http://localhost:8881${NC} while mining"
    echo ""
    echo -e "  ${BOLD}Configuration:${NC}"
    echo -e "    Edit ${CYAN}$CONFIG_FILE${NC}"
    echo ""
    echo -e "  ${BOLD}Logs:${NC}"
    echo -e "    ${CYAN}$LOG_DIR/${NC}"
    echo ""
    echo -e "  ${BLUE}DagTech Mining Suite v${DAGTECH_VERSION}${NC}"
    echo -e "  ${BLUE}By Dawie Nel / DagTech Ltd${NC}"
    echo -e "  ${BLUE}https://dagtech.network${NC}"
    echo ""
}

# ============================================================================
# Main Installation Flow
# ============================================================================
main() {
    print_banner

    info "Starting DagTech Miner installation..."
    echo ""

    check_os
    check_architecture
    check_cpu
    check_gpu
    install_dependencies
    configure_miner
    build_miner
    install_dashboard
    create_launcher
    setup_path
    setup_systemd_service
    print_summary
}

main "$@"
