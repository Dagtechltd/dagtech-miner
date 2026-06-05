#!/usr/bin/env python3
"""DagTech Miner Dashboard Server v3.1
Serves the dashboard UI and provides API endpoints for:
- GET  /api/metrics   — proxied from miner's metrics port
- GET  /api/config    — read current config.env
- POST /api/config    — write config.env
- POST /api/restart   — restart the miner process
- GET  /api/hardware  — detect CPU, GPU, RAM, OS
- GET  /api/diagnose  — installer-sensitivity diagnostics (NEW v3.1)

v3.1 changes:
- Install path auto-discovered from script location (no hardcoded ~/.dagtech-miner)
- restart_miner() returns ACTIONABLE errors (launcher missing, config missing, dev-wallet)
- New /api/diagnose endpoint surfaces install-integrity issues to the dashboard banner
"""
import http.server, json, os, platform, re, signal, subprocess, sys, urllib.request

DD = os.path.dirname(os.path.abspath(__file__))
MU = "http://127.0.0.1:8880/"

# Dev wallet — Inno Setup ships this as the default. Refuse to mine to it.
DEV_WALLET = "0x6387C32cCDD60BfBa00EC70A67715Dcd52E8083f"


def discover_install_paths():
    """Auto-detect install layout. Tries (in order):
      1. Sibling of this script (dashboard_server.py lives in <install>/dashboard/)
      2. ~/.dagtech-miner (legacy path)
      3. ~/dagtech-miner (no-dot variant — what the Inno Setup wizard produces when
         users edit the default path)
    Returns dict with bin_dir, config_file, log_dir, install_dir, source.
    """
    candidates = []

    # 1. Derive from this script's location (most reliable)
    script_install = os.path.normpath(os.path.join(DD, ".."))
    candidates.append(("script_relative", script_install))

    # 2. Standard dot path
    candidates.append(("user_dot", os.path.join(os.path.expanduser("~"), ".dagtech-miner")))

    # 3. No-dot variant (Inno Setup wizard footgun)
    candidates.append(("user_nodot", os.path.join(os.path.expanduser("~"), "dagtech-miner")))

    bin_name = "dagtech-start.bat" if platform.system() == "Windows" else "dagtech-start"

    for source, root in candidates:
        bin_dir = os.path.join(root, "bin")
        if os.path.isdir(bin_dir) and os.path.exists(os.path.join(bin_dir, bin_name)):
            return {
                "install_dir": root,
                "bin_dir": bin_dir,
                "config_file": _find_config(root),
                "log_dir": os.path.join(root, "logs"),
                "source": source,
            }

    # Nothing found — return script-relative anyway, dashboard will diagnose
    return {
        "install_dir": script_install,
        "bin_dir": os.path.join(script_install, "bin"),
        "config_file": _find_config(script_install),
        "log_dir": os.path.join(script_install, "logs"),
        "source": "fallback",
    }


def _find_config(root):
    """Config can live in install dir OR ~/.dagtech-miner (legacy). Prefer install dir."""
    candidates = [
        os.path.join(root, "config.env"),
        os.path.join(os.path.expanduser("~"), ".dagtech-miner", "config.env"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return candidates[0]  # default to install-dir path even if missing


PATHS = discover_install_paths()
CONFIG_FILE = PATHS["config_file"]
BIN_DIR = PATHS["bin_dir"]
LOG_DIR = PATHS["log_dir"]
INSTALL_DIR = PATHS["install_dir"]


def diagnose():
    """Return list of installer-integrity issues — surfaced to dashboard banner.
    Each issue is {severity, code, message, fix}.
    """
    issues = []
    bin_name = "dagtech-start.bat" if platform.system() == "Windows" else "dagtech-start"
    cpu_name = "dagtech-miner.exe" if platform.system() == "Windows" else "dagtech-miner"

    # Config presence
    if not os.path.exists(CONFIG_FILE):
        issues.append({
            "severity": "error", "code": "CONFIG_MISSING",
            "message": f"config.env not found at {CONFIG_FILE}",
            "fix": "Re-run the installer wizard to generate config.env, or create it manually with WALLET, POOL_HOST, POOL_PORT.",
        })

    # Launcher presence
    launcher = os.path.join(BIN_DIR, bin_name)
    if not os.path.exists(launcher):
        issues.append({
            "severity": "error", "code": "LAUNCHER_MISSING",
            "message": f"Launcher script not found at {launcher}",
            "fix": f"Install path may be wrong. Files were expected under {INSTALL_DIR}. Re-run installer or copy/move install folder.",
        })

    # Binary presence
    cpu_bin = os.path.join(BIN_DIR, cpu_name)
    if not os.path.exists(cpu_bin):
        issues.append({
            "severity": "error", "code": "BINARY_MISSING",
            "message": f"Miner binary not found at {cpu_bin}",
            "fix": "Install appears incomplete. Re-run the installer.",
        })

    # Config sanity
    if os.path.exists(CONFIG_FILE):
        cfg = read_config()
        wallet = cfg.get("WALLET", "").strip()
        if not wallet:
            issues.append({
                "severity": "error", "code": "WALLET_EMPTY",
                "message": "WALLET is empty in config.env",
                "fix": "Open Settings tab and set your BlockDAG wallet address.",
            })
        elif not re.match(r"^0x[0-9a-fA-F]{40}$", wallet):
            issues.append({
                "severity": "error", "code": "WALLET_MALFORMED",
                "message": f"WALLET '{wallet}' is not a valid 0x address (need 0x + 40 hex chars).",
                "fix": "Open Settings tab and paste the full wallet address.",
            })
        elif wallet.lower() == DEV_WALLET.lower():
            issues.append({
                "severity": "error", "code": "WALLET_IS_DEV_DEFAULT",
                "message": "WALLET is set to the bundled developer wallet — rewards would go to the developer, not you.",
                "fix": "Open Settings tab and set YOUR own wallet address before starting.",
            })

        host = cfg.get("POOL_HOST", "").strip()
        if host in ("", "127.0.0.1", "localhost"):
            issues.append({
                "severity": "warning", "code": "POOL_LOCALHOST",
                "message": f"POOL_HOST is '{host}' — miner will try to connect to your own machine.",
                "fix": "Change POOL_HOST to excalibur.dagtech.network in the Settings tab.",
            })

    return issues


def read_config():
    """Read config.env into a dict."""
    cfg = {}
    if not os.path.exists(CONFIG_FILE):
        return cfg
    with open(CONFIG_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


def write_config(cfg):
    """Write config dict back to config.env."""
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    lines = [
        "# DagTech Miner Configuration",
        "# Generated by DagTech Dashboard v3.1",
        "# https://dagtech.network",
        "",
    ]
    key_order = [
        "WALLET", "POOL_HOST", "POOL_PORT", "MINING_MODE", "THREADS",
        "WORKER_NAME", "POOL_PASSWORD", "LOW_PRIORITY", "METRICS_PORT",
        "GPU_INTENSITY", "GPU_THROTTLE", "CPU_LIMIT",
    ]
    written = set()
    for k in key_order:
        if k in cfg:
            lines.append(f"{k}={cfg[k]}")
            written.add(k)
    for k, v in cfg.items():
        if k not in written:
            lines.append(f"{k}={v}")
    with open(CONFIG_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")


def detect_hardware():
    """Detect CPU, GPU, RAM, and OS info."""
    hw = {"cpu": "", "cores": 0, "arch": "", "gpu": "", "gpu_vram": "", "ram_mb": 0, "os": ""}

    hw["os"] = f"{platform.system()} {platform.release()}"
    hw["arch"] = platform.machine()

    try:
        hw["cores"] = os.cpu_count() or 0
    except Exception:
        pass

    if platform.system() == "Linux":
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if "model name" in line:
                        hw["cpu"] = line.split(":")[1].strip()
                        break
            with open("/proc/meminfo") as f:
                for line in f:
                    if "MemTotal" in line:
                        hw["ram_mb"] = int(re.findall(r"\d+", line)[0]) // 1024
                        break
        except Exception:
            pass
        try:
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode == 0 and r.stdout.strip():
                parts = r.stdout.strip().split(",")
                hw["gpu"] = parts[0].strip()
                hw["gpu_vram"] = parts[1].strip() if len(parts) > 1 else ""
        except Exception:
            pass

    elif platform.system() == "Darwin":
        try:
            r = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, timeout=5)
            hw["cpu"] = r.stdout.strip()
            r = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=5)
            hw["ram_mb"] = int(r.stdout.strip()) // (1024 * 1024)
            r = subprocess.run(["system_profiler", "SPHardwareDataType"], capture_output=True, text=True, timeout=10)
            for line in r.stdout.splitlines():
                if "Chip" in line:
                    hw["gpu"] = line.split(":")[1].strip() + " (integrated)"
                    break
        except Exception:
            pass

    elif platform.system() == "Windows":
        try:
            r = subprocess.run(
                ["wmic", "cpu", "get", "Name", "/value"],
                capture_output=True, text=True, timeout=5, shell=True,
            )
            for line in r.stdout.splitlines():
                if "Name=" in line:
                    hw["cpu"] = line.split("=")[1].strip()
                    break
            r = subprocess.run(
                ["wmic", "os", "get", "TotalVisibleMemorySize", "/value"],
                capture_output=True, text=True, timeout=5, shell=True,
            )
            for line in r.stdout.splitlines():
                if "TotalVisibleMemorySize=" in line:
                    hw["ram_mb"] = int(line.split("=")[1].strip()) // 1024
                    break
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode == 0 and r.stdout.strip():
                parts = r.stdout.strip().split(",")
                hw["gpu"] = parts[0].strip()
                hw["gpu_vram"] = parts[1].strip() if len(parts) > 1 else ""
        except Exception:
            pass

    return hw


def stop_miner():
    """Stop the miner process."""
    system = platform.system()
    try:
        if system == "Windows":
            subprocess.run(["taskkill", "/f", "/im", "dagtech-miner.exe"], capture_output=True, timeout=5)
            subprocess.run(["taskkill", "/f", "/im", "dagtech-gpu-miner.exe"], capture_output=True, timeout=5)
        else:
            subprocess.run(["pkill", "-f", "dagtech-miner"], capture_output=True, timeout=5)
            subprocess.run(["pkill", "-f", "dagtech-gpu-miner"], capture_output=True, timeout=5)
        return True
    except Exception as e:
        return str(e)


def restart_miner():
    """Stop and restart the miner process.
    Returns True on success, or a dict {error, code, fix} for actionable failures.
    """
    # Pre-flight: any blocking diagnostics? If so, refuse to start with actionable message.
    blockers = [i for i in diagnose() if i["severity"] == "error"]
    if blockers:
        first = blockers[0]
        return {
            "error": first["message"],
            "code": first["code"],
            "fix": first["fix"],
            "additional_issues": [i["code"] for i in blockers[1:]],
        }

    system = platform.system()
    bin_name = "dagtech-start.bat" if system == "Windows" else "dagtech-start"
    start_script = os.path.join(BIN_DIR, bin_name)

    if not os.path.exists(start_script):
        return {
            "error": f"Launcher not found at {start_script}",
            "code": "LAUNCHER_MISSING",
            "fix": f"Install path mismatch. Expected files under {INSTALL_DIR}.",
        }

    try:
        if system == "Windows":
            subprocess.run(["taskkill", "/f", "/im", "dagtech-miner.exe"], capture_output=True, timeout=5)
            subprocess.run(["taskkill", "/f", "/im", "dagtech-gpu-miner.exe"], capture_output=True, timeout=5)
            subprocess.Popen(["cmd", "/c", "start", "/min", start_script], shell=True, cwd=BIN_DIR)
        else:
            subprocess.run(["pkill", "-f", "dagtech-miner"], capture_output=True, timeout=5)
            subprocess.run(["pkill", "-f", "dagtech-gpu-miner"], capture_output=True, timeout=5)
            subprocess.Popen([start_script], start_new_session=True, cwd=BIN_DIR)
        return True
    except Exception as e:
        return {"error": str(e), "code": "SPAWN_FAILED", "fix": "Check Windows Event Viewer Application log."}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=DD, **k)

    def _json_response(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/metrics":
            try:
                with urllib.request.urlopen(
                    urllib.request.Request(MU, headers={"Accept": "application/json"}),
                    timeout=3,
                ) as r:
                    d = r.read()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Content-Length", len(d))
                self.end_headers()
                self.wfile.write(d)
            except Exception as e:
                self._json_response(502, {"error": str(e)})

        elif self.path == "/api/config":
            try:
                cfg = read_config()
                self._json_response(200, cfg)
            except Exception as e:
                self._json_response(500, {"error": str(e)})

        elif self.path == "/api/hardware":
            try:
                hw = detect_hardware()
                self._json_response(200, hw)
            except Exception as e:
                self._json_response(500, {"error": str(e)})

        elif self.path == "/api/diagnose":
            try:
                self._json_response(200, {
                    "install_dir": INSTALL_DIR,
                    "config_file": CONFIG_FILE,
                    "bin_dir": BIN_DIR,
                    "path_source": PATHS["source"],
                    "issues": diagnose(),
                })
            except Exception as e:
                self._json_response(500, {"error": str(e)})

        else:
            super().do_GET()

    def do_POST(self):
        if self.path == "/api/config":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length)
                new_cfg = json.loads(body)
                existing = read_config()
                existing.update(new_cfg)
                write_config(existing)
                self._json_response(200, {"status": "saved", "config": existing})
            except Exception as e:
                self._json_response(500, {"error": str(e)})

        elif self.path == "/api/restart":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length)) if length > 0 else {}
                action = body.get("action", "restart")
                if action == "stop":
                    stop_miner()
                    self._json_response(200, {"status": "stopped"})
                else:
                    result = restart_miner()
                    if result is True:
                        self._json_response(200, {"status": "restarting"})
                    else:
                        # Actionable error — dashboard banner can show {error, code, fix}
                        self._json_response(409, result)
            except Exception as e:
                self._json_response(500, {"error": str(e)})

        else:
            self._json_response(404, {"error": "not found"})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    mp = int(sys.argv[2]) if len(sys.argv) > 2 else 8880
    MU = f"http://127.0.0.1:{mp}/"
    p = int(sys.argv[1]) if len(sys.argv) > 1 else 8881
    print(f"[DASH] DagTech Dashboard v3.1 on :{p}, metrics from :{mp}")
    print(f"[DASH] Install dir: {INSTALL_DIR} (discovered via {PATHS['source']})")
    print(f"[DASH] Config: {CONFIG_FILE}")
    print(f"[DASH] Hardware detection: {platform.system()} {platform.machine()}")
    issues = diagnose()
    if issues:
        print(f"[DASH] {len(issues)} integrity issue(s) detected:")
        for i in issues:
            print(f"  [{i['severity'].upper()}] {i['code']}: {i['message']}")
    http.server.HTTPServer(("0.0.0.0", p), Handler).serve_forever()
