#!/usr/bin/env python3
"""Nameserver checker: moves the zones' nameservers from Cloudflare to deSEC
when Cloudflare's DNS is really down, and back when it has recovered.

Design: infrastructure #77 and docs/ha/runbooks/dns-switch-to-standby.md.
Same shape as the RO checker next to it: each checker asks Cloudflare's
nameservers for every zone, serves its view, reads the others', and when
enough of them agree for long enough, changes the nameservers at Porkbun.
Setting the nameservers a zone already has is harmless, so there is no
leader.

A checker that can't get an answer from deSEC either is looking at its own
broken network, and its vote doesn't count.
"""

import json
import os
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import dns.message
import dns.query
import dns.rcode
import dns.rdatatype
import dns.resolver

CFG = json.load(open(sys.argv[1]))
STATE_FILE = os.path.join(os.environ.get("STATE_DIRECTORY", "/tmp"), "ns-state.json")
CRED_DIR = os.environ.get("CREDENTIALS_DIRECTORY", "")
API = "https://api.porkbun.com/api/json/v3/domain"

# cf[zone] = {"ok": bool, "since": t}: whether Cloudflare answers for the
# zone here, and since when that has been so.
view = {"name": CFG["name"], "self_ok": None, "cf": {}, "ts": 0}
view_lock = threading.Lock()
ns_addresses = {}  # nameserver name -> last known addresses


def log(msg):
    print(msg, flush=True)


def credential(name):
    with open(os.path.join(CRED_DIR, name)) as f:
        return f.read().strip()


def addresses(name):
    """A nameserver's addresses, remembered: while Cloudflare is down its own
    nameservers' names may not resolve either."""
    try:
        found = sorted({a[4][0] for a in socket.getaddrinfo(name, 53, socket.AF_INET)})
        if found:
            ns_addresses[name] = found
    except OSError:
        pass
    return ns_addresses.get(name, [])


def answers(zone, nameservers):
    """True if any of the nameservers answers the zone's SOA with authority."""
    q = dns.message.make_query(zone, dns.rdatatype.SOA)
    for ns in nameservers:
        for ip in addresses(ns):
            try:
                r = dns.query.udp(q, ip, timeout=3)
            except Exception:
                continue
            if r.rcode() == dns.rcode.NOERROR and r.answer:
                return True
    return False


def probe():
    now = time.time()
    self_ok = any(answers(z, CFG["desec_ns"]) for z in CFG["zones"])
    cf = {}
    if self_ok:
        for z in CFG["zones"]:
            cf[z] = answers(z, CFG["cloudflare_ns"])
    with view_lock:
        view["self_ok"] = self_ok
        for z, ok in cf.items():
            old = view["cf"].get(z)
            if old is None or old["ok"] != ok:
                view["cf"][z] = {"ok": ok, "since": now}
        view["ts"] = now


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


def porkbun(action, zone, extra=None):
    body = {"apikey": credential("porkbun_api_key"),
            "secretapikey": credential("porkbun_secret_api_key"), **(extra or {})}
    req = urllib.request.Request(f"{API}/{action}/{zone}", data=json.dumps(body).encode(),
                                 method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        reply = json.load(r)
    if reply.get("status") != "SUCCESS":
        raise RuntimeError(f"porkbun {action} {zone}: {reply.get('message')}")
    return reply


def on_desec(zone):
    """Whether the zone's nameservers at Porkbun are deSEC's."""
    ns = [n.lower().rstrip(".") for n in porkbun("getNs", zone).get("ns", [])]
    return any(n in CFG["desec_ns"] for n in ns)


def notify(title, message, emergency=False, tag=None, resolves=False):
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


def load_state():
    try:
        return json.load(open(STATE_FILE))
    except Exception:
        return {"last_switch": {}, "dry_last": {}}


def save_state(state):
    json.dump(state, open(STATE_FILE, "w"))


def switch(zone, to_desec, state):
    ns = CFG["desec_ns"] if to_desec else CFG["cloudflare_ns"]
    what = f"{zone}: nameservers to {'deSEC' if to_desec else 'Cloudflare'} ({', '.join(ns)})"
    if CFG["dry_run"]:
        if state["dry_last"].get(zone) != what:
            log("DRY RUN: would switch " + what)
            notify("Nameserver switch (dry run)", f"Would switch {what}. Nothing was changed.")
            state["dry_last"][zone] = what
            save_state(state)
        return
    log("switching " + what)
    porkbun("updateNs", zone, {"ns": ns})
    state["last_switch"][zone] = time.time()
    save_state(state)
    if to_desec:
        notify("Cloudflare DNS is down", f"Switched {what}. It takes hours to spread; sites are "
               "reached without Cloudflare's proxy meanwhile.", emergency=True, tag=f"ns-{zone}")
    else:
        notify("Cloudflare DNS is back", f"Switched {what}.", tag=f"ns-{zone}", resolves=True)


def decide(state):
    now = time.time()
    with view_lock:
        own = json.loads(json.dumps(view))
    views = [own] + peer_views()
    valid = [v for v in views if v.get("name") in CFG["voters"]
             and v.get("self_ok") and now - v.get("ts", 0) < 3 * CFG["interval"]]
    if len(valid) < CFG["quorum"]:
        return f"waiting: {len(valid)} usable voters, need {CFG['quorum']}"
    summary = []
    for zone in CFG["zones"]:
        seen = [v["cf"].get(zone) for v in valid if v["cf"].get(zone)]
        down = sum(1 for s in seen if not s["ok"] and now - s["since"] >= CFG["fail_after"])
        up = sum(1 for s in seen if s["ok"] and now - s["since"] >= CFG["back_after"])
        anyone_down = any(not s["ok"] for s in seen)
        summary.append(f"{zone}={'down' if anyone_down else 'ok'}")
        if not (down >= CFG["quorum"] or (up >= CFG["quorum"] and not anyone_down)):
            continue
        # Only ask Porkbun when a switch could be due.
        try:
            switched = on_desec(zone)
        except Exception as e:
            log(f"{zone}: can't read its nameservers at Porkbun: {e}")
            continue
        if down >= CFG["quorum"] and not switched:
            if now - state["last_switch"].get(zone, 0) < CFG["min_interval"]:
                log(f"{zone}: Cloudflare down but the last switch was too recent, not acting")
                continue
            switch(zone, True, state)
        elif up >= CFG["quorum"] and not anyone_down and switched:
            switch(zone, False, state)
    return f"{len(valid)} voters; " + " ".join(summary)


def main():
    host, port = CFG["listen"].rsplit(":", 1)
    threading.Thread(target=ThreadingHTTPServer((host, int(port)), Handler).serve_forever,
                     daemon=True).start()
    state = load_state()
    last_msg = None
    log(f"{CFG['name']} started, voters {CFG['voters']} (quorum {CFG['quorum']}), dry run {CFG['dry_run']}")
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
