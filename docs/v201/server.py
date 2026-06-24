#!/usr/bin/env python3
# DagTech Local Dashboard - tiny static + log tail server
# Binds 127.0.0.1:8881 only. No deps beyond Python stdlib.
# Copyright (c) DagTech Ltd. CONFIDENTIAL.
import os
import sys
import json
import glob
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

HOST = "127.0.0.1"
PORT = 8881
HOME = os.path.expanduser("~")
DASHBOARD_DIR = os.path.join(HOME, ".dagtech-node")
DASHBOARD_HTML = os.path.join(DASHBOARD_DIR, "dashboard.html")
LOG_DIRS = [
    os.path.join(HOME, ".dagtech-node", "log"),
    os.path.join(HOME, ".dagtech-node", "logs"),
    "/var/log/dagtech-node",
]
VERSION_FILE = os.path.join(DASHBOARD_DIR, "VERSION")
DEFAULT_VERSION = "v2.0.1"

def find_latest_log():
    candidates = []
    for d in LOG_DIRS:
        if os.path.isdir(d):
            for f in glob.glob(os.path.join(d, "*.log")):
                try:
                    candidates.append((os.path.getmtime(f), f))
                except OSError:
                    pass
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]

def tail(path, n=20):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            block = 8192
            data = b""
            while size > 0 and data.count(b"\n") <= n:
                read = min(block, size)
                size -= read
                f.seek(size)
                data = f.read(read) + data
            lines = data.decode("utf-8", errors="replace").splitlines()
            return "\n".join(lines[-n:])
    except Exception as e:
        return "log read error: %s" % e

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        body_bytes = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/" or path == "/index.html" or path == "/dashboard.html":
            try:
                with open(DASHBOARD_HTML, "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except FileNotFoundError:
                self._send(404, "dashboard.html missing at " + DASHBOARD_HTML)
            return
        if path == "/log":
            lp = find_latest_log()
            if not lp:
                self._send(200, "(no log files found in " + " or ".join(LOG_DIRS) + ")")
                return
            self._send(200, tail(lp, 20))
            return
        if path == "/version":
            v = DEFAULT_VERSION
            try:
                with open(VERSION_FILE) as f:
                    v = f.read().strip() or DEFAULT_VERSION
            except OSError:
                pass
            self._send(200, v)
            return
        if path == "/health":
            self._send(200, "ok")
            return
        self._send(404, "not found")

def main():
    try:
        srv = HTTPServer((HOST, PORT), Handler)
    except OSError as e:
        sys.stderr.write("bind failed: %s\n" % e)
        sys.exit(1)
    sys.stderr.write("DagTech local dashboard on http://%s:%d (no external calls, ever)\n" % (HOST, PORT))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
