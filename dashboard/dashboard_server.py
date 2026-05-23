#!/usr/bin/env python3
"""DagTech Miner Dashboard Server - Proxies metrics from miner to web dashboard."""
import http.server, json, os, urllib.request, sys

DD = os.path.dirname(os.path.abspath(__file__))
MU = "http://127.0.0.1:8880/"

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=DD, **k)

    def do_GET(self):
        if self.path == '/api/metrics':
            try:
                with urllib.request.urlopen(
                    urllib.request.Request(MU, headers={'Accept': 'application/json'}),
                    timeout=3
                ) as r:
                    d = r.read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Content-Length', len(d))
                self.end_headers()
                self.wfile.write(d)
            except Exception as e:
                er = json.dumps({"error": str(e)}).encode()
                self.send_response(502)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', len(er))
                self.end_headers()
                self.wfile.write(er)
        else:
            super().do_GET()

    def log_message(self, *a):
        pass

if __name__ == '__main__':
    mp = int(sys.argv[2]) if len(sys.argv) > 2 else 8880
    MU = f"http://127.0.0.1:{mp}/"
    p = int(sys.argv[1]) if len(sys.argv) > 1 else 8881
    print(f"[DASH] Dashboard on :{p}, metrics from :{mp}")
    http.server.HTTPServer(('0.0.0.0', p), Handler).serve_forever()
