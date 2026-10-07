#!/usr/bin/env python3
"""Failover checker: moves ro.radunenu.com to the edge when RO is down.

Design: docs/ha/failover.md in the infrastructure repo. Each checker probes
RO from outside, serves its view on the tailnet, reads the other checkers'
views, and when every voter agrees for long enough, points ro at the edge
(or back). Setting a record to the value it already has is harmless, so
there is no leader.
"""

import json
import os
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import dns.resolver

CFG = json.load(open(sys.argv[1]))
STATE_FILE = os.path.join(os.environ.get("STATE_DIRECTORY", "/tmp"), "state.json")
CRED_DIR = os.environ.get("CREDENTIALS_DIRECTORY", "")

view = {"name": CFG["name"], "self_ok": None, "ro_ok": None, "since": time.time(), "ts": 0}
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
    """RO's current address, from public resolvers."""
    for ns in ("1.1.1.1", "9.9.9.9"):
        try:
            return resolver(ns).resolve(name, "A")[0].to_text()
        except Exception:
            continue
    return None


def traefik_answers(ip):
    """True if Traefik answers on ip:443 with its 404 for an unknown host."""
    host = "edge-check.invalid"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((ip, 443), timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                s.settimeout(5)
                s.sendall(f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                status = s.recv(64).split(b" ")
                return len(status) > 1 and status[1] == b"404"
    except Exception:
        return False


def network_ok():
    """Our own uplink works: the DNS providers' APIs are reachable."""
    for host in ("api.cloudflare.com", "desec.io"):
        try:
            socket.create_connection((host, 443), timeout=5).close()
        except Exception:
            return False
    return True


def probe():
    self_ok = network_ok()
    ro_ok = None
    if self_ok:
        ip = resolve_a(CFG["ro_dynamic_name"])
        ro_ok = bool(ip) and traefik_answers(ip)
    with view_lock:
        if ro_ok != view["ro_ok"]:
            view["since"] = time.time()
        view.update(self_ok=self_ok, ro_ok=ro_ok, ts=time.time())


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
    """What ro points at right now, straight from Cloudflare's nameservers."""
    try:
        ns_ip = socket.gethostbyname(CFG["cloudflare_nameserver"])
        ans = resolver(ns_ip).resolve(CFG["ro_name"], "CNAME")
        return ans[0].target.to_text().rstrip(".")
    except Exception:
        return None


def api(method, url, token_header, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Content-Type": "application/json", **token_header})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r) if r.length != 0 else None


def set_cloudflare(target):
    auth = {"Authorization": "Bearer " + credential("cloudflare_token")}
    base = "https://api.cloudflare.com/client/v4"
    zone = api("GET", f"{base}/zones?name={CFG['cloudflare_zone']}", auth)["result"][0]["id"]
    rec = api("GET", f"{base}/zones/{zone}/dns_records?type=CNAME&name={CFG['ro_name']}", auth)["result"][0]
    api("PATCH", f"{base}/zones/{zone}/dns_records/{rec['id']}", auth, {"content": target})


def set_desec(target, apex_ip):
    auth = {"Authorization": "Token " + credential("desec_token")}
    base = "https://desec.io/api/v1/domains"
    zone = CFG["cloudflare_zone"]
    sub = CFG["ro_name"][: -len(zone) - 1]
    api("PATCH", f"{base}/{zone}/rrsets/{sub}/CNAME/", auth, {"records": [target + "."]})
    for z in CFG["desec_apex_zones"]:
        api("PATCH", f"{base}/{z}/rrsets/@/A/", auth, {"records": [apex_ip]})
        time.sleep(1)  # deSEC rate limits


def load_state():
    try:
        return json.load(open(STATE_FILE))
    except Exception:
        return {"last_switch": 0, "desec_apex_ip": None}


def save_state(state):
    json.dump(state, open(STATE_FILE, "w"))


def dry_run(state, msg):
    """In dry run, log what would happen, once per distinct action."""
    if state.get("dry_last") != msg:
        log("DRY RUN: would " + msg)
        state["dry_last"] = msg


def notify(title, message, emergency=False, tag=None, resolves=False):
    """Tell the alert relay on the edge. Never let a failed notification stop a switch."""
    body = json.dumps({"title": title, "message": message, "emergency": emergency,
                       "tag": tag, "resolves": resolves}).encode()
    for url in CFG["relay_urls"]:
        try:
            urllib.request.urlopen(urllib.request.Request(
                url, data=body, method="POST",
                headers={"Content-Type": "application/json"}), timeout=10)
            return
        except Exception as e:
            log(f"notify via {url} failed: {e}")


def switch(to_edge, state):
    target = CFG["edge_name"] if to_edge else CFG["ro_dynamic_name"]
    apex_ip = CFG["edge_ip"] if to_edge else resolve_a(CFG["ro_dynamic_name"])
    what = "failover to the edge" if to_edge else "fail back to RO"
    if CFG["dry_run"]:
        msg = f"{what}: ro -> {target}, deSEC apexes -> {apex_ip}"
        if state.get("dry_last") != msg:
            notify("Failover (dry run)", "Would " + msg + ". Nothing was changed.")
        dry_run(state, msg)
        return
    log(f"{what}: ro -> {target}, deSEC apexes -> {apex_ip}")
    set_cloudflare(target)
    set_desec(target, apex_ip)
    state.update(last_switch=time.time(), desec_apex_ip=apex_ip)
    save_state(state)
    if to_edge:
        notify("RO is down", "Traffic now goes through the edge to DK. RO-only services are down until RO is back.",
               emergency=True, tag="ro-failover")
    else:
        notify("RO is back", "Traffic goes to RO again.", tag="ro-failover", resolves=True)


def decide(state):
    now = time.time()
    with view_lock:
        own = dict(view)
    views = [own] + peer_views()
    voters = [v for v in views if v.get("name") in CFG["voters"]]
    valid = [v for v in voters if v.get("self_ok") and now - v.get("ts", 0) < 60]
    current = current_target()
    summary = ", ".join(f"{v['name']}={v.get('ro_ok')}" for v in voters) or "none"

    # RO looks down from here, but the votes can't make it happen: say so, once.
    stuck = own["ro_ok"] is False and now - own["since"] >= 2 * CFG["fail_after"] and current != CFG["edge_name"]
    if len(valid) < len(CFG["voters"]):
        reason = f"only {len(valid)} of {len(CFG['voters'])} voters usable ({summary})"
        if stuck and not state.get("stuck_reported"):
            notify("Failover can't act", f"RO looks down from {CFG['name']}, but {reason}.", emergency=True)
            state["stuck_reported"] = True
        return "waiting: " + reason
    if own["ro_ok"]:
        state["stuck_reported"] = False
    if current is None:
        return "waiting: can't read ro from Cloudflare"

    down_for = min(now - v["since"] for v in valid) if all(v["ro_ok"] is False for v in valid) else 0
    up_for = min(now - v["since"] for v in valid) if all(v["ro_ok"] for v in valid) else 0
    on_edge = current == CFG["edge_name"]

    if not on_edge and down_for >= CFG["fail_after"]:
        if now - state["last_switch"] < CFG["min_interval"]:
            return f"RO down {down_for:.0f}s but last switch was too recent, not acting"
        switch(True, state)
        return f"RO down on every voter: {'would fail' if CFG['dry_run'] else 'failed'} over"
    if on_edge and up_for >= CFG["back_after"]:
        switch(False, state)
        return f"RO healthy on every voter: {'would fail' if CFG['dry_run'] else 'failed'} back"

    # Normal operation: keep deSEC's apexes on RO's current address.
    if not on_edge and up_for > 0:
        ip = resolve_a(CFG["ro_dynamic_name"])
        if ip and ip != state.get("desec_apex_ip"):
            if CFG["dry_run"]:
                dry_run(state, f"set deSEC apexes to RO's address {ip}")
            else:
                for z in CFG["desec_apex_zones"]:
                    api("PATCH", f"https://desec.io/api/v1/domains/{z}/rrsets/@/A/",
                        {"Authorization": "Token " + credential("desec_token")}, {"records": [ip]})
                    time.sleep(1)
                state["desec_apex_ip"] = ip
                save_state(state)
                log(f"deSEC apexes now on RO's address {ip}")
    where = "edge" if on_edge else "RO"
    return f"ro on {where}; votes: {summary}"


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
            msg = decide(state) if CFG["name"] in CFG["voters"] else "observer"
        except Exception as e:
            msg = f"error: {e}"
        if msg != last_msg:
            log(msg)
            last_msg = msg
        time.sleep(CFG["interval"])


if __name__ == "__main__":
    main()
