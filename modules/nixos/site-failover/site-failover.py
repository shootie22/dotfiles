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

- follow: for a service with `cnpg` clusters (Matrix), while this node runs
  it, a primary in the other site is switched over to the instance here, so
  the service never queries its database across the WAN. Only once the
  cluster is healthy and the primary has been elsewhere for FOLLOW_AFTER
  seconds, and at most once every PROMOTE_EVERY seconds.

GET /<service> says what this node thinks: on localhost for checks by hand,
and on the mesh address for the game relay (modules/nixos/game-relay.nix),
which sends players to whichever node holds the label.
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


def mount_targets():
    with open("/proc/self/mountinfo") as f:
        return [line.split()[4] for line in f]


def is_mounted(path):
    # os.path.ismount misses a bind mount within the same filesystem.
    return path in mount_targets()


def bind(src, dst):
    # Recursive: a service's folder can have mounts inside it (Gitea's
    # repositories live on another disk), and a plain bind leaves those out.
    targets = mount_targets()
    if dst in targets:
        nested = [t[len(src):] for t in targets if t.startswith(src + "/")]
        if all(dst + n in targets for n in nested):
            return None
        run("umount", "-R", "-l", dst)
        log(f"{dst}: nested mounts missing, binding again")
    os.makedirs(dst, exist_ok=True)
    return run("mount", "--rbind", src, dst)


def ha_path(svc):
    return f"/srv/ha/{svc}"


def stateless(svc):
    return cfg["services"][svc].get("stateless", False)


def data(svc):
    if stateless(svc):
        return "/"  # nothing on disk; always "there"
    # The service's folder here. May be a pattern (a local-path volume's
    # folder has a generated name); it counts only if it matches exactly one
    # folder.
    matches = [m for m in glob.glob(cfg["services"][svc]["data"]) if os.path.isdir(m)]
    return matches[0] if len(matches) == 1 else None


def has_copy(svc):
    if stateless(svc):
        return True
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
            # The folder itself or anything in it: Audiobookshelf and Baikal
            # mount subfolders, and were missed (drill on 2026-10-07).
            src = lambda m: m.get("source") or ""
            if any(src(m) == path or src(m).startswith(path + "/") for m in mounts):
                with open(os.path.join(TASKS, cid, "init.pid")) as f:
                    found.append((cid, int(f.read().strip())))
        except (OSError, ValueError):
            continue
    return found


def fence(svc):
    if stateless(svc):
        return
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
        r = run("umount", "-R", "-l", path)
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
    if stateless(svc):
        return
    path = ha_path(svc)
    r = bind(data(svc), path)
    if r is not None:
        log(f"{svc}: active here, {path} ready" if r.returncode == 0 else f"{svc}: bind failed: {r.stderr.strip()}")


def ensure_incoming():
    # Where the peer's copies arrive, when that isn't the folder itself.
    for svc, s in cfg["services"].items():
        target, d = s["incoming"], data(svc)
        if target and d:
            r = bind(d, target)
            if r is not None:
                log(f"{svc}: copies arrive in {target}" if r.returncode == 0 else f"{svc}: bind at {target} failed: {r.stderr.strip()}")


# A primary that has just moved (CNPG's own failover, or a switchover in
# progress) is left alone this long before following it.
FOLLOW_AFTER = 60
# A switchover pauses writes for a few seconds; never more than one per
# cluster in this long, whatever flaps.
PROMOTE_EVERY = 600
CHECK_EVERY = 15
# (service, cluster) -> since when the primary has been elsewhere, the last
# switchover, and whether it's elsewhere now (for the metric).
follow = {}
follow_checked = {"at": 0.0}


def pod_ready(pod):
    return any(c["type"] == "Ready" and c["status"] == "True"
               for c in pod.get("status", {}).get("conditions", []))


def follow_db():
    if time.time() - follow_checked["at"] < CHECK_EVERY:
        return
    follow_checked["at"] = time.time()
    for svc, s in cfg["services"].items():
        c = s.get("cnpg")
        if not c:
            continue
        for cluster in c["clusters"]:
            st = follow.setdefault((svc, cluster), {"since": None, "last": 0.0, "elsewhere": False})
            if not allowed(svc):
                # The other node runs the service; it does the following.
                st.update(since=None, elsewhere=False)
                continue
            if state["holders"].get(svc) != [NODE]:
                # Two holders (a label set by hand without taking the other
                # off): both would switch the primary to themselves, in turn.
                # Never; a human sorts out the labels first.
                if st["since"] is not None or not st.get("warned"):
                    log(f"{svc}: held by {state['holders'].get(svc)}, not only by this node; not moving {cluster}")
                st.update(since=None, warned=True)
                continue
            st["warned"] = False
            r = kubectl("-n", c["namespace"], "get", "cluster", cluster, "-o", "json")
            p = kubectl("-n", c["namespace"], "get", "pods", "-l", f"cnpg.io/cluster={cluster},cnpg.io/podRole=instance", "-o", "json")
            if r.returncode != 0 or p.returncode != 0:
                continue
            status = json.loads(r.stdout).get("status", {})
            pods = json.loads(p.stdout)["items"]
            primary = status.get("currentPrimary")
            where = next((x["spec"].get("nodeName") for x in pods if x["metadata"]["name"] == primary), None)
            here = [x["metadata"]["name"] for x in pods
                    if x["spec"].get("nodeName") == NODE and pod_ready(x) and x["metadata"]["name"] != primary]
            st["elsewhere"] = where != NODE
            if not st["elsewhere"] or not here:
                st["since"] = None
                continue
            # Nothing while CNPG is busy: a failover or switchover underway,
            # an instance not ready, replication not caught up.
            if status.get("phase") != "Cluster in healthy state" or status.get("targetPrimary") != primary:
                continue
            now = time.time()
            if st["since"] is None:
                st["since"] = now
                log(f"{svc}: {cluster}'s primary {primary} is on {where}, not here; switching over in {FOLLOW_AFTER} s if it stays")
                continue
            if now - st["since"] < FOLLOW_AFTER or now - st["last"] < PROMOTE_EVERY:
                continue
            st["last"], st["since"] = now, None
            r = run(*cfg["cnpg_cli"], "-n", c["namespace"], "promote", cluster, here[0], timeout=30)
            log(f"{svc}: {cluster}: switchover to {here[0]} " +
                ("started" if r.returncode == 0 else f"failed: {(r.stderr or r.stdout).strip()}"))


METRICS = "/var/lib/node-exporter-textfile/site_failover.prom"


def write_metrics():
    # For Prometheus (node-exporter's textfile collector): which services this
    # node runs, and whether it could reach the cluster. Alerts: a service run
    # by no node, or by two; and a node that lost the cluster.
    fresh = time.time() - state["api_ok_at"] < cfg["api_grace"]
    lines = [
        "# HELP site_failover_active Whether this node runs the service (holds the label and may run it).",
        "# TYPE site_failover_active gauge",
    ]
    for svc in cfg["services"]:
        lines.append(f'site_failover_active{{service="{svc}"}} {1 if allowed(svc) else 0}')
    lines += [
        "# HELP site_failover_cluster_reachable Whether this node reached the cluster recently.",
        "# TYPE site_failover_cluster_reachable gauge",
        f"site_failover_cluster_reachable {1 if fresh else 0}",
    ]
    if follow:
        lines += [
            "# HELP site_failover_db_elsewhere Whether a database that follows a service this node runs has its primary on another node.",
            "# TYPE site_failover_db_elsewhere gauge",
        ]
        for (svc, cluster), st in follow.items():
            lines.append(f'site_failover_db_elsewhere{{service="{svc}",cluster="{cluster}"}} {1 if st["elsewhere"] else 0}')
    try:
        tmp = METRICS + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, METRICS)
    except OSError as e:
        log(f"metrics: {e}")


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
        try:
            follow_db()
        except Exception as e:
            log(f"following databases: {e}")
        write_metrics()
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


def serve(address):
    # The mesh address may not be there yet at boot; keep trying, without
    # ever holding up the loop above.
    while True:
        try:
            ThreadingHTTPServer((address, cfg["port"]), Gate).serve_forever()
        except OSError as e:
            log(f"status page on {address}: {e}; retrying")
            time.sleep(10)


threading.Thread(target=loop, daemon=True).start()
for address in cfg["listen"][1:]:
    threading.Thread(target=serve, args=(address,), daemon=True).start()
serve(cfg["listen"][0])
