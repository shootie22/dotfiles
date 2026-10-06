"""Site failover for services with files (infrastructure, decision 2026-10-06).

Each service runs on one of two nodes, the one labelled
ha.radunenu.com/<service>=active, and mounts /srv/ha/<service>. This runs on
both nodes and does three things:

- claim: when the node holding the label has not been Ready for `fail_after`
  seconds (counted from when the cluster marked it so), this node takes the
  label, if a whole copy of the service's folder has arrived here. Only the
  node taking over writes the label, through the cluster's API, so a node
  that's cut off can't.
- fence: /srv/ha/<service> exists only while this node may run the service:
  it holds the label and reached the cluster in the last `api_grace` seconds.
  Otherwise any container using the folder is killed (found through the
  container runtime's files, so it works while containerd is down too), and
  the folder goes away, so kubelet can't restart it. A node that's cut
  off stops by itself, before the other site takes over.
- open: when this node may run the service, /srv/ha/<service> is a bind of
  the service's folder here.

GET /<service> on localhost says what this node thinks (for checks by hand).
"""

import glob
import json
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

cfg = json.load(open(sys.argv[1]))
NODE = cfg["node"]
PREFIX = "ha.radunenu.com/"
state = {"api_ok_at": 0.0, "labels": {}, "holders": {}}


def log(msg):
    print(msg, flush=True)


def run(*args, timeout=15):
    try:
        return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timed out")


def kubectl(*args):
    return run(*cfg["k3s"], "kubectl", "--request-timeout=8s", *args)


def is_mounted(path):
    # os.path.ismount misses a bind mount within the same filesystem.
    with open("/proc/self/mountinfo") as f:
        return any(line.split()[4] == path for line in f)


def ha_path(svc):
    return f"/srv/ha/{svc}"


def data(svc):
    # The service's folder here. May be a pattern (a local-path volume's
    # folder has a generated name); it counts only if it matches exactly one
    # folder.
    matches = [m for m in glob.glob(cfg["services"][svc]["data"]) if os.path.isdir(m)]
    return matches[0] if len(matches) == 1 else None


def has_copy(svc):
    # A whole copy has arrived at least once (standby-copy.nix writes it last).
    d = data(svc)
    return d is not None and os.path.exists(os.path.join(d, ".standby-copy-ok"))


def allowed(svc):
    fresh = time.time() - state["api_ok_at"] < cfg["api_grace"]
    mine = state["labels"].get(PREFIX + svc) == "active"
    return fresh and mine and data(svc) is not None


def ready(node):
    for c in node["status"].get("conditions", []):
        if c["type"] == "Ready":
            since = datetime.fromisoformat(c["lastTransitionTime"].replace("Z", "+00:00")).timestamp()
            return c["status"] == "True", since
    return False, 0.0


def claim(svc, old):
    key = PREFIX + svc
    # The old holder's label goes first: never two holders. If the second
    # step fails, the next round finds no holder and claims again.
    if old:
        r = kubectl("label", "node", old, f"{key}-")
        if r.returncode != 0:
            log(f"{svc}: couldn't take the label off {old}: {r.stderr.strip()}")
            return
    r = kubectl("label", "node", NODE, f"{key}=active", "--overwrite")
    if r.returncode == 0:
        log(f"{svc}: now active here" + (f", taken over from {old}" if old else ""))
    else:
        log(f"{svc}: couldn't label this node: {r.stderr.strip()}")


def tick():
    r = kubectl("get", "nodes", "-o", "json")
    if r.returncode != 0:
        return
    nodes = {n["metadata"]["name"]: n for n in json.loads(r.stdout)["items"]}
    me = nodes.get(NODE)
    if me is None:
        return
    state["api_ok_at"] = time.time()
    state["labels"] = me["metadata"].get("labels", {})
    if not ready(me)[0]:
        return

    for svc, s in cfg["services"].items():
        key = PREFIX + svc
        holders = [n for n, x in nodes.items() if x["metadata"].get("labels", {}).get(key) == "active"]
        state["holders"][svc] = holders
        if NODE in holders or data(svc) is None:
            continue
        peer = nodes.get(s["peer"])
        peer_ok, since = ready(peer) if peer else (False, 0.0)
        if not holders:
            # Nobody has it: the first time (where the live data is), or a
            # move that stopped halfway.
            if s["initial"] or (not peer_ok and has_copy(svc)):
                claim(svc, None)
        elif holders != [s["peer"]]:
            log(f"{svc}: held by {holders}, not by this node's peer; leaving it alone")
        elif not peer_ok and time.time() - since >= cfg["fail_after"]:
            if has_copy(svc):
                claim(svc, s["peer"])
            else:
                log(f"{svc}: {s['peer']} is gone but no whole copy ever arrived here; not taking over")


TASKS = "/run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io"


def containers_using(path):
    # Read from each running container's bundle, not asked of containerd: on a
    # server cut off from etcd's majority, k3s keeps exiting and containerd
    # with it, while the containers carry on.
    found = []
    try:
        ids = os.listdir(TASKS)
    except FileNotFoundError:
        return found
    for cid in ids:
        try:
            with open(os.path.join(TASKS, cid, "config.json")) as f:
                mounts = json.load(f).get("mounts", [])
            if any(m.get("source") == path for m in mounts):
                with open(os.path.join(TASKS, cid, "init.pid")) as f:
                    found.append((cid, int(f.read().strip())))
        except (OSError, ValueError):
            continue
    return found


def fence(svc):
    path = ha_path(svc)
    for cid, pid in containers_using(path):
        try:
            os.kill(pid, signal.SIGKILL)
            log(f"{svc}: killed container {cid[:12]} (pid {pid})")
        except ProcessLookupError:
            pass
    if not os.path.lexists(path):
        return
    if is_mounted(path):
        r = run("umount", "-l", path)
        if r.returncode != 0:
            log(f"{svc}: couldn't unmount {path}: {r.stderr.strip()}")
            return
    try:
        os.rmdir(path)
    except OSError as e:
        log(f"{svc}: couldn't remove {path}: {e}")
    log(f"{svc}: fenced (cluster {'reachable' if time.time() - state['api_ok_at'] < cfg['api_grace'] else 'lost'}, "
        f"label {'here' if state['labels'].get(PREFIX + svc) == 'active' else 'elsewhere'})")


def open_(svc):
    path = ha_path(svc)
    if is_mounted(path):
        return
    os.makedirs(path, exist_ok=True)
    r = run("mount", "--bind", data(svc), path)
    log(f"{svc}: active here, {path} ready" if r.returncode == 0 else f"{svc}: bind failed: {r.stderr.strip()}")


def ensure_incoming():
    # Where the peer's copies arrive, when that isn't the folder itself.
    for svc, s in cfg["services"].items():
        target, d = s["incoming"], data(svc)
        if target and d and not is_mounted(target):
            os.makedirs(target, exist_ok=True)
            r = run("mount", "--bind", d, target)
            log(f"{svc}: copies arrive in {target}" if r.returncode == 0 else f"{svc}: bind at {target} failed: {r.stderr.strip()}")


def loop():
    while True:
        try:
            ensure_incoming()
            tick()
        except Exception as e:
            log(f"round failed: {e}")
        # The fence runs every round, whatever happened above.
        for svc in cfg["services"]:
            try:
                open_(svc) if allowed(svc) else fence(svc)
            except Exception as e:
                log(f"{svc}: {e}")
        time.sleep(cfg["interval"])


class Gate(BaseHTTPRequestHandler):
    def do_GET(self):
        svc = self.path.strip("/")
        if svc not in cfg["services"]:
            self.send_response(404)
            self.end_headers()
            return
        fresh = time.time() - state["api_ok_at"] < cfg["api_grace"]
        mine = state["labels"].get(PREFIX + svc) == "active"
        self.send_response(200 if allowed(svc) else 503)
        self.end_headers()
        holders = ",".join(state["holders"].get(svc, [])) or "none"
        self.wfile.write(f"cluster={'ok' if fresh else 'lost'} active={mine} copy={has_copy(svc)} holder={holders}\n".encode())

    def log_message(self, *args):
        pass


threading.Thread(target=loop, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", cfg["port"]), Gate).serve_forever()
