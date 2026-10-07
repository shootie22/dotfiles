#!/usr/bin/env python3
"""Front checker: points element.radunenu.com (and with it c.nuke.zip) at
RO's front door while the edge can't serve Element Web, and back at the edge
when it can again (infrastructure #160).

Same shape as the other checkers next to it: each one fetches Element Web
through the edge and through RO, serves its view, reads the others', and
acts when every usable voter agrees. A false alarm is cheap here, since RO
serves Element Web too, so one voter is enough when it's the only one left.
"""

import json
import os
import socket
import ssl
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import dns.resolver

CFG = json.load(open(sys.argv[1]))
STATE_FILE = os.path.join(os.environ.get("STATE_DIRECTORY", "/tmp"), "front-state.json")
CRED_DIR = os.environ.get("CREDENTIALS_DIRECTORY", "")

view = {"name": CFG["name"], "self_ok": None, "edge_ok": None, "ro_ok": None,
        "since": time.time(), "ts": 0}
view_lock = threading.Lock()


def log(msg):
    print(msg, flush=True)


def credential(name):
    with open(os.path.join(CRED_DIR, name)) as f:
        return f.read().strip()


def resolver(nameserver):
    r = dns.resolver.Resolver(configure=False)
    r.nameservers = [nameserver]
    r.lifetime = 5
    return r


def resolve_a(name):
    for ns in ("1.1.1.1", "9.9.9.9"):
        try:
            return resolver(ns).resolve(name, "A")[0].to_text()
        except Exception:
            continue
    return None


def serves_element(ip):
    """True if ip answers Element Web's /version for the real name, with a
    valid certificate."""
    host = CFG["site"]
    ctx = ssl.create_default_context()
    try:
        with socket.create_connection((ip, 443), timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                s.settimeout(5)
                s.sendall(f"GET /version HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                status = s.recv(64).split(b" ")
                return len(status) > 1 and status[1] == b"200"
    except Exception:
        return False


def network_ok():
    for host in ("api.cloudflare.com", "desec.io"):
        try:
            socket.create_connection((host, 443), timeout=5).close()
        except Exception:
            return False
    return True


def probe():
    self_ok = network_ok()
    edge_ok = ro_ok = None
    if self_ok:
        edge_ok = serves_element(CFG["edge_ip"])
        ro_ip = resolve_a(CFG["ro_name"])
        ro_ok = bool(ro_ip) and serves_element(ro_ip)
    with view_lock:
        if edge_ok != view["edge_ok"]:
            view["since"] = time.time()
        view.update(self_ok=self_ok, edge_ok=edge_ok, ro_ok=ro_ok, ts=time.time())


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with view_lock:
            body = json.dumps(view).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def peer_views():
    views = []
    for url in CFG["peers"]:
        try:
            with urllib.request.urlopen(url, timeout=3) as r:
                views.append(json.load(r))
        except Exception:
            pass
    return views


def current_target():
    try:
        ns_ip = socket.gethostbyname(CFG["cloudflare_nameserver"])
        ans = resolver(ns_ip).resolve(CFG["record"], "CNAME")
        return ans[0].target.to_text().rstrip(".")
    except Exception:
        return None


def api(method, url, auth, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", **auth})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r) if r.length != 0 else None


def set_target(target):
    auth = {"Authorization": "Bearer " + credential("cloudflare_token")}
    base = "https://api.cloudflare.com/client/v4"
    zone = api("GET", f"{base}/zones?name={CFG['zone']}", auth)["result"][0]["id"]
    rec = api("GET", f"{base}/zones/{zone}/dns_records?type=CNAME&name={CFG['record']}", auth)["result"][0]
    api("PATCH", f"{base}/zones/{zone}/dns_records/{rec['id']}", auth, {"content": target})
    sub = CFG["record"][: -len(CFG["zone"]) - 1]
    api("PATCH", f"https://desec.io/api/v1/domains/{CFG['zone']}/rrsets/{sub}/CNAME/",
        {"Authorization": "Token " + credential("desec_token")}, {"records": [target + "."]})


def notify(title, message, emergency=False):
    body = json.dumps({"title": title, "message": message, "emergency": emergency}).encode()
    for url in CFG["relay_urls"]:
        try:
            urllib.request.urlopen(urllib.request.Request(
                url, data=body, method="POST",
                headers={"Content-Type": "application/json"}), timeout=10)
            return
        except Exception as e:
            log(f"notify via {url} failed: {e}")


def load_state():
    try:
        return json.load(open(STATE_FILE))
    except Exception:
        return {"last_switch": 0}


def switch(to_ro, state):
    target = CFG["ro_name"] if to_ro else CFG["edge_name"]
    what = f"{CFG['record']} -> {target}"
    if CFG["dry_run"]:
        if state.get("dry_last") != what:
            log("DRY RUN: would point " + what)
            notify("Element Web front (dry run)", f"Would point {what}. Nothing was changed.")
            state["dry_last"] = what
        return
    log("pointing " + what)
    set_target(target)
    state["last_switch"] = time.time()
    json.dump(state, open(STATE_FILE, "w"))
    if to_ro:
        notify("Element Web moved to RO", "The edge stopped serving it, so c.nuke.zip now goes "
               "to RO's front door. Back to the edge 10 minutes after it's healthy again.")
    else:
        notify("Element Web back on the edge", "The edge serves it again.")


def decide(state):
    now = time.time()
    with view_lock:
        own = dict(view)
    views = [own] + peer_views()
    valid = [v for v in views if v.get("name") in CFG["voters"]
             and v.get("self_ok") and now - v.get("ts", 0) < 60]
    if not valid:
        return "waiting: no usable voters"
    current = current_target()
    if current is None:
        return "waiting: can't read the record from Cloudflare"
    summary = ", ".join(f"{v['name']}: edge={v['edge_ok']} ro={v['ro_ok']}" for v in valid)
    on_ro = current == CFG["ro_name"]
    if not on_ro and all(v["edge_ok"] is False for v in valid):
        down_for = min(now - v["since"] for v in valid)
        if down_for >= CFG["fail_after"] and all(v["ro_ok"] for v in valid):
            if now - state["last_switch"] < CFG["min_interval"]:
                return f"edge down {down_for:.0f}s but the last switch was too recent; {summary}"
            switch(True, state)
            return f"edge down: {'would move' if CFG['dry_run'] else 'moved'} to RO; {summary}"
    if on_ro and all(v["edge_ok"] for v in valid):
        up_for = min(now - v["since"] for v in valid)
        if up_for >= CFG["back_after"]:
            switch(False, state)
            return f"edge healthy: {'would move' if CFG['dry_run'] else 'moved'} back; {summary}"
    return f"on {'RO' if on_ro else 'the edge'}; {summary}"


def main():
    host, port = CFG["listen"].rsplit(":", 1)
    threading.Thread(target=ThreadingHTTPServer((host, int(port)), Handler).serve_forever,
                     daemon=True).start()
    state = load_state()
    last_msg = None
    log(f"{CFG['name']} started, voters {CFG['voters']}, dry run {CFG['dry_run']}")
    while True:
        try:
            probe()
            msg = decide(state)
        except Exception as e:
            msg = f"error: {e}"
        if msg != last_msg:
            log(msg)
            last_msg = msg
        time.sleep(CFG["interval"])


if __name__ == "__main__":
    main()
