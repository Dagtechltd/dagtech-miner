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
