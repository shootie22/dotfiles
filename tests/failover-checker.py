"""Tests for the failover checker's view of RO (modules/nixos/failover-checker).

  nix build .#checks.x86_64-linux.failover-checker -L

Covers infrastructure incident 2026-10-14: fuji's Traefik answered while
fuji was cut off from the cluster, so the checkers kept RO "up". RO now also
needs fuji's site-failover status page to say cluster=ok, unless this
checker can't read the mesh at all.
"""

import importlib.util
import json
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The checker reads its settings from argv when imported.
cfg = {"name": "test", "voters": ["test"], "listen": "127.0.0.1:0", "ro_dynamic_name": "ro.example"}
cfg_file = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
json.dump(cfg, cfg_file)
cfg_file.close()
sys.argv = ["checker", cfg_file.name]
spec = importlib.util.spec_from_file_location("checker", os.environ["CHECKER"])
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

failures = []


def check(name, got, want):
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {name}: got {got!r}, want {want!r}")
    if not ok:
        failures.append(name)


# A status page like site-failover's: (code, body) per path.
pages = {}


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        code, body = pages.get(self.path, (404, ""))
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"
pages["/fuji-ok"] = (200, "cluster=ok active=True copy=True holder=fuji\n")
pages["/fuji-standby"] = (503, "cluster=ok active=False copy=True holder=thinkcentre\n")
pages["/fuji-lost"] = (503, "cluster=lost active=True copy=True holder=fuji\n")
pages["/garbage"] = (200, "hello\n")
dead = "http://127.0.0.1:1/gitea"  # nothing listens: no answer

print("cluster_status")
check("200 cluster=ok", checker.cluster_status(base + "/fuji-ok"), "ok")
check("503 but cluster=ok (standby for the service)", checker.cluster_status(base + "/fuji-standby"), "ok")
check("503 cluster=lost", checker.cluster_status(base + "/fuji-lost"), "lost")
check("no cluster= line", checker.cluster_status(base + "/garbage"), None)
check("nothing listening", checker.cluster_status(dead), None)

print("ro_health")
check("Traefik down", checker.ro_health(False, "ok", "ok")[0], False)
check("Traefik up, fuji in the cluster", checker.ro_health(True, "ok", None)[0], True)
check("Traefik up, fuji lost the cluster", checker.ro_health(True, "lost", "ok")[0], False)
check("2026-10-14: Traefik up, fuji silent, mesh fine", checker.ro_health(True, None, "ok")[0], False)
check("Traefik up, fuji silent, this checker's mesh broken", checker.ro_health(True, None, None)[0], True)

print("probe, end to end")
checker.network_ok = lambda: True
checker.resolve_a = lambda name: "192.0.2.1"


def probe_with(traefik, fuji_url, reference_url):
    checker.traefik_answers = lambda ip: traefik
    checker.CFG["ro_cluster_status"] = fuji_url
    checker.CFG["mesh_reference_status"] = reference_url
    checker.probe()
    return checker.view["ro_ok"]


check("all healthy", probe_with(True, base + "/fuji-ok", base + "/fuji-ok"), True)
check("2026-10-14 again", probe_with(True, dead, base + "/fuji-ok"), False)
check("why is recorded", checker.view["why"], "fuji's status page doesn't answer over the mesh")
check("checker's own mesh broken", probe_with(True, dead, dead), True)
check("fuji says lost", probe_with(True, base + "/fuji-lost", base + "/fuji-ok"), False)
check("Traefik down", probe_with(False, base + "/fuji-ok", base + "/fuji-ok"), False)
checker.CFG.pop("ro_cluster_status")
checker.traefik_answers = lambda ip: True
checker.probe()
check("no cluster check configured: Traefik decides", checker.view["ro_ok"], True)

if failures:
    print(f"{len(failures)} failed: {failures}")
    sys.exit(1)
print("all passed")
