"""Site failover for services with files (infrastructure, decision 2026-10-06).

Each service runs on one of two nodes, the one labelled
ha.radunenu.com/<service>=active, and mounts /srv/ha/<service>. This runs on
both nodes and does three things:

- claim: when the node holding the label has not been Ready for `fail_after`
  seconds (counted from when the cluster marked it so), this node takes the
  label, if a whole copy of the service's folder has arrived here. Only the
  node taking over writes the label, through the cluster's API, so a node
  that's cut off can't.
  Also when the holder is up but can't run the service: a workload of the
  service has no pod running and one has been stuck Pending there for
  `unfit_after` seconds, unschedulable or never getting its containers
  started (the thinkcentre's disk under kubelet's eviction threshold on
  2026-10-20: Ready all along, every pod evicted, nothing moved). Not for a
  pod that can't pull its image (it couldn't on this node either) or one
  that crashes once started. At most once per `hold_down` seconds per
  service, so one that can run nowhere doesn't bounce, and never onto a
  node under pressure itself.
- fence: /srv/ha/<service> exists only while this node may run the service:
  it holds the label and reached the cluster in the last `api_grace` seconds.
  Otherwise any container using the folder is killed (found through the
  container runtime's files, so it works while containerd is down too), and
  the folder goes away, so kubelet can't restart it. A node that's cut
  off stops by itself, before the other site takes over.
- open: when this node may run the service, /srv/ha/<service> is a bind of
  the service's folder here, and /run/site-failover/active/<service> exists:
  standby-copy.nix refuses the peer's copies of a service that runs here, so
  an old holder that's still up can't write over the live folder. Copies
  under way when this node takes over are stopped.

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
ACTIVE_DIR = "/run/site-failover/active"
state = {"api_ok_at": 0.0, "labels": {}, "holders": {}}
# svc -> (holders, when they last changed), as seen from here; the hold-down
# counts from it.
seen = {}
# (svc, reason) -> when it was last logged.
warned = {}


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


PRESSURE = ("DiskPressure", "MemoryPressure", "PIDPressure")


def pressure(node):
    return [c["type"] for c in node["status"].get("conditions", [])
            if c["type"] in PRESSURE and c["status"] == "True"]


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


# Waiting reasons the other node would hit just the same.
NOT_THE_NODE = ("ErrImagePull", "ImagePullBackOff", "InvalidImageName", "CreateContainerConfigError")
# A pod on its node but not started yet may just be pulling a big image
# (that shows as ContainerCreating too), so it gets this much longer.
START_GRACE = 600


def stuck_since(pod):
    """Since when a Pending pod has been stuck on its node; None if it isn't."""
    st = pod.get("status", {})
    sched = next((c for c in st.get("conditions", []) if c["type"] == "PodScheduled"), None)
    if sched is None:
        return None
    if sched["status"] == "False":
        return ts(sched["lastTransitionTime"]) if sched.get("reason") == "Unschedulable" else None
    waiting = [c.get("state", {}).get("waiting", {}).get("reason")
               for c in st.get("initContainerStatuses", []) + st.get("containerStatuses", [])]
    if any(w in NOT_THE_NODE for w in waiting):
        return None
    return ts(sched["lastTransitionTime"]) + START_GRACE


def workload(pod):
    # Pods of one Deployment or StatefulSet share their labels, apart from
    # the revision. A Job's (Send's cleanup) don't count: they come and go.
    if any(o.get("kind") == "Job" for o in pod["metadata"].get("ownerReferences", [])):
        return None
    skip = ("pod-template-hash", "controller-revision-hash", "statefulset.kubernetes.io/pod-name", "apps.kubernetes.io/pod-index")
    labels = {k: v for k, v in pod["metadata"].get("labels", {}).items() if k not in skip}
    return (pod["metadata"]["namespace"], tuple(sorted(labels.items())))


def tied_to(pod, svc):
    # The workload picks its node by the label (nodeSelector or affinity).
    return f'"{PREFIX}{svc}"' in json.dumps(pod["spec"])


class Pods:
    """The cluster's Pending pods, fetched at most once a round; Running ones
    only for a namespace where a Pending one of a service turns up."""

    def __init__(self):
        self.pending, self.running = None, {}

    def get(self, *selector):
        r = kubectl("get", "pods", *selector, "-o", "json")
        if r.returncode != 0:
            raise RuntimeError(f"listing pods: {r.stderr.strip()}")
        return json.loads(r.stdout)["items"]

    def pending_of(self, svc):
        if self.pending is None:
            self.pending = self.get("-A", "--field-selector=status.phase=Pending")
        return [p for p in self.pending if tied_to(p, svc) and workload(p)]

    def running_in(self, ns):
        if ns not in self.running:
            self.running[ns] = {workload(p) for p in self.get("-n", ns, "--field-selector=status.phase=Running")}
        return self.running[ns]


def unfit(svc, holder, pods):
    """What shows `holder` can't run svc, and since when; None if nothing."""
    worst = None
    for p in pods.pending_of(svc):
        if p["spec"].get("nodeName") not in (None, holder):
            continue
        since = stuck_since(p)
        if since is None or workload(p) in pods.running_in(p["metadata"]["namespace"]):
            continue
        if worst is None or since < worst[1]:
            worst = (f"{p['metadata']['namespace']}/{p['metadata']['name']} stuck Pending", since)
    return worst


def warn(svc, reason, msg):
    # The same reason once every 10 minutes, not every round.
    if time.time() - warned.get((svc, reason), 0) > 600:
        log(f"{svc}: {msg}")
        warned[(svc, reason)] = time.time()


def mark(svc, on):
    path = os.path.join(ACTIVE_DIR, svc)
    if on and not os.path.exists(path):
        os.makedirs(ACTIVE_DIR, exist_ok=True)
        open(path, "w").close()
    elif not on and os.path.exists(path):
        os.remove(path)


def stop_incoming(svc):
    # A copy from the old holder that started before the label moved would
    # go on writing into what is now the live folder. rrsync runs rsync in
    # the sender's folder (<receive dir>/<peer>), on <service>/.
    s = cfg["services"][svc]
    base = os.path.dirname(s["receive"])
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().decode(errors="replace").split("\0")
            if "--server" not in argv or not os.path.basename(argv[0]).startswith("rsync"):
                continue
            if os.readlink(f"/proc/{pid}/cwd") != base:
                continue
            if not any(a.rstrip("/") == svc or a.startswith(svc + "/") for a in argv):
                continue
            os.kill(int(pid), signal.SIGKILL)
            log(f"{svc}: stopped a copy from {s['peer']} that was still under way (pid {pid})")
        except (OSError, ValueError):
            continue


def claim(svc, old, why=None):
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
        log(f"{svc}: now active here" + (f", taken over from {old}" if old else "") + (f": {why}" if why else ""))
        if not stateless(svc):
            # The old holder's copies are refused from now on, and any under
            # way stopped: the folder here is the live one.
            mark(svc, True)
            stop_incoming(svc)
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
    pods = Pods()

    for svc, s in cfg["services"].items():
        key = PREFIX + svc
        holders = [n for n, x in nodes.items() if x["metadata"].get("labels", {}).get(key) == "active"]
        state["holders"][svc] = holders
        if svc not in seen:
            seen[svc] = (holders, 0.0)  # not a move: a restart of this daemon
        elif seen[svc][0] != holders:
            seen[svc] = (holders, time.time())
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
        elif peer_ok:
            bad = unfit(svc, s["peer"], pods)
            if bad is None or time.time() - bad[1] < cfg["unfit_after"]:
                continue
            why = f"{bad[0]} on {s['peer']} for {time.time() - bad[1]:.0f} s"
            if pressure(peer):
                why += f", {s['peer']} under {'/'.join(pressure(peer))}"
            moved = time.time() - seen[svc][1]
            if pressure(me):
                warn(svc, "pressure", f"{why}; not taking over, this node is under {'/'.join(pressure(me))} too")
            elif moved < cfg["hold_down"]:
                warn(svc, "hold", f"{why}; not taking over, it moved {moved:.0f} s ago (hold-down {cfg['hold_down']} s)")
            elif not has_copy(svc):
                warn(svc, "copy", f"{why}; not taking over, no whole copy ever arrived here")
            else:
                claim(svc, s["peer"], why)


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
    mark(svc, False)
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
    mark(svc, True)
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
