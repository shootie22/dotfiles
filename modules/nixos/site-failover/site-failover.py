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

- place: every CNPG cluster's primary goes back to where it belongs by
  itself (infrastructure docs/ha/decisions.md, 2026-10-21): next to the
  service it follows (placement.radunenu.com/follows on the Cluster, or the
  `cnpg` option), or in its home site (/home). The node it belongs on
  switches it over, once the cluster is healthy, nothing anywhere else is
  switching over, and it has been out of place for WAIT seconds; at most
  once every EVERY seconds per cluster. And a pod that requires a service's
  label, left on a node the label has moved away from, is deleted so it
  starts next to the service. A primary left in the other site after the
  2026-10-20 failover made every Gitea query cross the WAN for ten hours.

GET /<service> says what this node thinks: on localhost for checks by hand,
and on the mesh address for the game relay (modules/nixos/game-relay.nix),
which sends players to whichever node holds the label.
"""

import errno
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


# What the fence leaves at /srv/ha/<service>: nothing can be made below it.
FENCED = "/dev/null/fenced"


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
    # While handing it over (going home), it stays stopped here though the
    # label is still here.
    return fresh and mine and data(svc) is not None and svc not in handing


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
    state["nodes"] = nodes
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
    if is_mounted(path) or os.path.isdir(path):
        if is_mounted(path):
            r = run("umount", "-R", "-l", path)
            if r.returncode != 0:
                log(f"{svc}: couldn't unmount {path}: {r.stderr.strip()}")
                return
        try:
            os.rmdir(path)
        except OSError as e:
            if e.errno != errno.ENOTEMPTY:
                log(f"{svc}: couldn't remove {path}: {e}")
                return
            # Written by a container that restarted after the folder went, on
            # an empty one: never data to keep. Kept aside to look at.
            aside = f"/srv/ha/.stray/{svc}-{int(time.time())}"
            os.makedirs(os.path.dirname(aside), exist_ok=True)
            os.rename(path, aside)
            log(f"{svc}: {path} had been written to after it was fenced; moved to {aside}")
        log(f"{svc}: fenced (cluster {'reachable' if time.time() - state['api_ok_at'] < cfg['api_grace'] else 'lost'}, "
            f"label {'here' if state['labels'].get(PREFIX + svc) == 'active' else 'elsewhere'})")
    if not os.path.lexists(path):
        # A link into /dev/null where the folder was. containerd makes a
        # missing bind source into an empty folder for a container that
        # restarts, and the service then starts afresh on nothing (a
        # handover's VM test, 2026-10-21). It can't make one through this,
        # and kubelet doesn't take it as a folder, so nothing starts here.
        os.symlink(FENCED, path)


def open_(svc):
    if stateless(svc):
        return
    mark(svc, True)
    path = ha_path(svc)
    if os.path.islink(path) and os.readlink(path) == FENCED:
        os.remove(path)  # the fence's marker
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


# Placement (infrastructure docs/ha/decisions.md, 2026-10-21): everything has
# a declared place, and what isn't there is moved back by itself.
#
# - A CNPG cluster's primary: placement.radunenu.com/follows: <service> (where
#   site-failover runs that service) or /home: <site> on the Cluster, or this
#   module's `cnpg` option (follows). The node it belongs on does the
#   switchover, once the cluster is healthy and nothing else anywhere is
#   switching over, and it has been out of place for a while.
# - A pod that requires a service's label but runs on a node the label has
#   left (labels only steer scheduling): deleted by the holder, so it starts
#   next to the service again (Rybbit's backend next to its ClickHouse).
FOLLOWS = "placement.radunenu.com/follows"
HOME = "placement.radunenu.com/home"
ZONE = "topology.kubernetes.io/zone"
# A primary that has just moved (CNPG's own failover, or a switchover in
# progress) is left alone this long before it's moved: following a service
# right away, going home a little later.
WAIT = {"follows": 60, "home": 120}
# A switchover pauses writes for a few seconds; never more often than this per
# cluster, whatever flaps.
EVERY = {"follows": 600, "home": 3600}
CHECK_EVERY = 15
HEALTHY = "Cluster in healthy state"
# Strays only appear when a label moves; looked for this long after a move
# (and once at start).
STRAY_WINDOW = 1800
STRAY_AFTER = 60
# (namespace, cluster) -> since when out of place, the last switchover here,
# what it wants, where the primary is.
placed = {}
place_checked = {"at": 0.0}
strays_checked = {}


def moving(c):
    st = c.get("status", {})
    phase = (st.get("phase") or "").lower()
    return st.get("targetPrimary") != st.get("currentPrimary") or "switchover" in phase or "failing over" in phase


def pod_ready(pod):
    return any(c["type"] == "Ready" and c["status"] == "True"
               for c in pod.get("status", {}).get("conditions", []))


def holders_of(nodes, svc):
    return sorted(n for n, x in nodes.items() if x["metadata"].get("labels", {}).get(PREFIX + svc) == "active")


def legacy_follows():
    # The module's `cnpg` option, from before the annotations.
    out = {}
    for svc, s in cfg["services"].items():
        c = s.get("cnpg")
        for cluster in (c or {}).get("clusters", []):
            out[(c["namespace"], cluster)] = svc
    return out


def db_target(cluster, instances, nodes, legacy):
    """Where the cluster's primary belongs: (node, how, why); node None when
    that can't be said (no holder, two holders, no instance in the site)."""
    md = cluster["metadata"]
    key = (md["namespace"], md["name"])
    ann = md.get("annotations") or {}
    # The Cluster's own annotation wins over the module's option.
    follows = ann.get(FOLLOWS) or (None if ann.get(HOME) else legacy.get(key))
    if follows:
        h = holders_of(nodes, follows)
        if len(h) != 1:
            return None, "follows", f"{follows} is held by {h or 'no node'}"
        return h[0], "follows", f"follows {follows}"
    home = ann.get(HOME)
    if home:
        here = sorted({p["spec"].get("nodeName") for p in instances
                       if nodes.get(p["spec"].get("nodeName"), {}).get("metadata", {}).get("labels", {}).get(ZONE) == home})
        if len(here) != 1:
            return None, "home", f"{len(here)} instances in {home}"
        return here[0], "home", f"home {home}"
    return None, None, "no placement declared"


def db_move(cluster, instances, target, how, busy, me_ok, st, now):
    """What to do about one cluster on its target node: (action, detail),
    action one of "ok", "wait", "promote"."""
    status = cluster.get("status", {})
    primary = status.get("currentPrimary")
    where = next((p["spec"].get("nodeName") for p in instances if p["metadata"]["name"] == primary), None)
    if where == target:
        st["since"] = None
        return "ok", f"primary {primary} is here"
    if st["since"] is None:
        st["since"] = now
    here = [p["metadata"]["name"] for p in instances
            if p["spec"].get("nodeName") == target and pod_ready(p) and p["metadata"]["name"] != primary]
    if not here:
        return "wait", "no ready instance here"
    # Nothing while CNPG is busy here or anywhere (one move at a time): a
    # failover or switchover underway, an instance not ready, replication
    # behind.
    if status.get("phase") != HEALTHY or status.get("targetPrimary") != primary:
        return "wait", f"cluster is {status.get('phase')!r}"
    if busy:
        return "wait", f"{busy} is switching over"
    if not me_ok:
        return "wait", "this node isn't fit (pressure)"
    if now - st["since"] < WAIT[how]:
        return "wait", f"out of place for {now - st['since']:.0f} s, moving after {WAIT[how]} s"
    if now - st.get("last", 0.0) < EVERY[how]:
        return "wait", f"switched over {now - st['last']:.0f} s ago, not again within {EVERY[how]} s"
    return "promote", here[0]


def requires_label(pod, svc):
    key = PREFIX + svc
    spec = pod.get("spec", {})
    if (spec.get("nodeSelector") or {}).get(key) == "active":
        return True
    terms = (((spec.get("affinity") or {}).get("nodeAffinity") or {})
             .get("requiredDuringSchedulingIgnoredDuringExecution") or {}).get("nodeSelectorTerms") or []
    return bool(terms) and all(any(e.get("key") == key and e.get("operator") == "In" and "active" in e.get("values", [])
                                   for e in t.get("matchExpressions") or []) for t in terms)


def strays(pods, svc, holder):
    """Pods that require svc's label, running on a node that doesn't hold it."""
    return [p for p in pods
            if requires_label(p, svc) and p["spec"].get("nodeName") not in (None, holder)
            and not any(o.get("kind") == "Job" for o in p["metadata"].get("ownerReferences", []))
            and p["status"].get("phase") == "Running"]


def place():
    if time.time() - place_checked["at"] < CHECK_EVERY:
        return
    place_checked["at"] = now = time.time()
    nodes = state.get("nodes")
    if not nodes:
        return
    me = nodes.get(NODE)
    me_ok = me is not None and ready(me)[0] and not pressure(me)

    # Databases.
    r = kubectl("get", "clusters.postgresql.cnpg.io", "-A", "-o", "json")
    p = kubectl("get", "pods", "-A", "-l", "cnpg.io/podRole=instance", "-o", "json")
    if r.returncode == 0 and p.returncode == 0:
        clusters = json.loads(r.stdout)["items"]
        pods = json.loads(p.stdout)["items"]
        legacy = legacy_follows()
        by = {}
        for x in pods:
            by.setdefault((x["metadata"]["namespace"], x["metadata"]["labels"].get("cnpg.io/cluster")), []).append(x)
        # One move at a time: none while any cluster is switching or failing
        # over. Only that: a cluster that's merely unhealthy mustn't hold up
        # every other one.
        busy = next((f"{c['metadata']['namespace']}/{c['metadata']['name']}" for c in clusters if moving(c)), None)
        seen_now = set()
        for c in clusters:
            key = (c["metadata"]["namespace"], c["metadata"]["name"])
            inst = by.get(key, [])
            target, how, why = db_target(c, inst, nodes, legacy)
            if target is None and how:
                # Two holders (a label set by hand without taking the other
                # off) would have both nodes switch it to themselves, in turn.
                # Never; a human sorts out the labels first.
                warn(f"{key[0]}/{key[1]}", "unplaceable", f"{key[0]}/{key[1]}: {why}; not moving it")
            if target != NODE:
                # Another node's to move (or nobody's, for now).
                placed.pop(key, None)
                continue
            seen_now.add(key)
            st = placed.setdefault(key, {"since": None, "last": 0.0})
            action, detail = db_move(c, inst, target, how, busy if busy != f"{key[0]}/{key[1]}" else None, me_ok, st, now)
            primary = c.get("status", {}).get("currentPrimary")
            where = next((x["spec"].get("nodeName") for x in inst if x["metadata"]["name"] == primary), None)
            st.update(how=how, why=why, where=where, action=action, detail=detail)
            name = f"{key[0]}/{key[1]}"
            if action == "wait":
                warn(name, detail.split(" ")[0], f"{name}'s primary is on {where}, belongs here ({why}); {detail}")
            elif action == "promote":
                st["last"], st["since"] = now, None
                busy = name
                r = run(*cfg["cnpg_cli"], "-n", key[0], "promote", key[1], detail, timeout=30)
                log(f"{name}: switching the primary over to {detail} here ({why}): " +
                    ("started" if r.returncode == 0 else f"failed: {(r.stderr or r.stdout).strip()}"))
        for key in [k for k in placed if k not in seen_now]:
            placed.pop(key)

    # Pods left behind by a label that moved to this node.
    running = None
    for svc in cfg["services"]:
        if not allowed(svc) or state["holders"].get(svc) != [NODE]:
            continue
        moved = time.time() - seen.get(svc, ([], 0.0))[1]
        first = svc not in strays_checked
        if not first and moved > STRAY_WINDOW:
            continue
        if moved < STRAY_AFTER:
            continue
        strays_checked[svc] = now
        if running is None:
            r = kubectl("get", "pods", "-A", "--field-selector=status.phase=Running", "-o", "json")
            if r.returncode != 0:
                return
            running = json.loads(r.stdout)["items"]
        for x in strays(running, svc, NODE):
            ns, name = x["metadata"]["namespace"], x["metadata"]["name"]
            d = kubectl("-n", ns, "delete", "pod", name, "--wait=false")
            log(f"{svc}: {ns}/{name} was left on {x['spec'].get('nodeName')} after the label moved here; " +
                ("deleted, it starts here" if d.returncode == 0 else f"couldn't delete it: {d.stderr.strip()}"))


# Going home (infrastructure docs/ha/decisions.md, 2026-10-21): a service
# that isn't on its home node (`initial`) goes back with a planned move once
# the home node has been fit a while, in the quiet hours. Nothing is lost:
#
#   home node   asks: ha.radunenu.com/handover-<svc>: "<home> <time>" on the
#               holder's node
#   holder      stops the service (fences it, though it keeps the label: the
#               folder goes from /srv/ha, so it can't start again), sends a
#               last copy straight from the folder, and marks
#               ha.radunenu.com/handover-done-<svc>: "<time>"
#   home node   takes the label, clears both, deletes the stopped pod so it
#               starts here at once
#
# Either side gives up after `handover_timeout` (a failed copy, the other node
# gone): the request goes, and the service opens where it was. A node that dies
# halfway is an ordinary failover. A stateless service only moves its label.
HANDOVER = PREFIX + "handover-"
HANDED = PREFIX + "handover-done-"
SRC_DIR = "/run/standby-copy"
handing = {}  # svc -> this node is handing it over: phase, asked, inv
homing = {}   # svc -> this node is taking it home: since, last, failed, why


def in_window(now, window):
    a, b = window.split("-")
    t = time.localtime(now)
    m = t.tm_hour * 60 + t.tm_min
    sa, sb = int(a[:2]) * 60 + int(a[3:]), int(b[:2]) * 60 + int(b[3:])
    return sa <= m < sb if sa <= sb else (m >= sa or m < sb)


def annotation(node, key):
    return ((node or {}).get("metadata", {}).get("annotations") or {}).get(key)


def handover_anywhere(nodes):
    return next((f"{n}: {k[len(HANDOVER):]}" for n, x in nodes.items()
                 for k in (x["metadata"].get("annotations") or {}) if k.startswith(HANDOVER) and not k.startswith(HANDED)), None)


def home_blocker(svc, s, nodes, now, st, fresh, copy_ok):
    """Why svc can't be taken home to this node now; None when it can."""
    if not s.get("initial") or not s.get("go_home", True):
        return "not its home"
    if holders_of(nodes, svc) != [s["peer"]]:
        return "not held by the peer alone"
    if not fresh:
        return "can't reach the cluster"
    for name, x in sorted(nodes.items()):
        if not ready(x)[0] or pressure(x):
            return f"{name} isn't fit"
    up, since = ready(nodes[NODE])
    if now - since < cfg["home_fit_for"]:
        return f"this node has been fit for {now - since:.0f} s of {cfg['home_fit_for']}"
    if now - st.get("last", 0.0) < cfg["home_every"]:
        return "moved within the last hour"
    if st.get("failed") and now - st["failed"] < 12 * 3600:
        return "the last handover failed; next quiet hours"
    if not copy_ok:
        return "no whole copy here"
    busy = handover_anywhere(nodes)
    if busy:
        return f"a handover is under way ({busy})"
    if not in_window(now, cfg["home_window"]):
        return "quiet-hours"
    return None


def annotate(node, *kv):
    r = kubectl("annotate", "node", node, "--overwrite", *kv)
    if r.returncode != 0:
        log(f"annotating {node}: {r.stderr.strip()}")
    return r.returncode == 0


def unit(svc):
    r = run("systemctl", "show", f"standby-copy-{svc}.service", "-p", "ActiveState,Result,InvocationID")
    return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)


def delete_strays(svc, peer):
    r = kubectl("get", "pods", "-A", "--field-selector", f"spec.nodeName={peer}", "-o", "json")
    if r.returncode != 0:
        return
    for x in json.loads(r.stdout)["items"]:
        if requires_label(x, svc) and not any(o.get("kind") == "Job" for o in x["metadata"].get("ownerReferences", [])):
            ns, name = x["metadata"]["namespace"], x["metadata"]["name"]
            d = kubectl("-n", ns, "delete", "pod", name, "--wait=false")
            log(f"{svc}: {ns}/{name} on {peer} " + ("deleted, it starts here" if d.returncode == 0 else f"couldn't be deleted: {d.stderr.strip()}"))


def go_home():
    """The home node's side: ask, wait for the last copy, take over."""
    nodes = state.get("nodes")
    if not nodes or NODE not in nodes:
        return
    now = time.time()
    fresh = now - state["api_ok_at"] < cfg["api_grace"]
    for svc, s in cfg["services"].items():
        st = homing.setdefault(svc, {"since": None, "last": 0.0})
        peer = s["peer"]
        holders = holders_of(nodes, svc)
        if not s.get("initial") or holders == [NODE] or not holders:
            st["since"] = None
            continue
        if st["since"] is None:
            st["since"] = now
        req = annotation(nodes.get(peer), HANDOVER + svc)
        if req and req.split()[0] == NODE:
            asked = float(req.split()[1])
            done = annotation(nodes.get(peer), HANDED + svc)
            if done and float(done) >= asked and holders == [peer]:
                st["why"] = "handover"
                # If claim() fails it says why; the peer gives up on its own
                # once the request is gone.
                claim(svc, peer, "planned move home, the last copy is here")
                annotate(peer, f"{HANDOVER}{svc}-", f"{HANDED}{svc}-")
                st["last"], st["since"] = now, None
                delete_strays(svc, peer)
            elif now - asked > cfg["handover_timeout"]:
                annotate(peer, f"{HANDOVER}{svc}-")
                st["failed"] = now
                st["why"] = "handover timed out"
                log(f"{svc}: {peer} didn't hand it over within {cfg['handover_timeout']} s; withdrawn, next quiet hours")
            else:
                st["why"] = "handover"
            continue
        why = home_blocker(svc, s, nodes, now, st, fresh, stateless(svc) or has_copy(svc))
        st["why"] = why
        if why is not None:
            if why != "quiet-hours":
                warn(svc, "home:" + why.split(" ")[0], f"{svc} is on {holders}, its home is here; not moving it: {why}")
            continue
        if stateless(svc):
            claim(svc, peer, "going home")
            st["last"], st["since"] = now, None
            delete_strays(svc, peer)
            continue
        if annotate(peer, f"{HANDOVER}{svc}={NODE} {now:.0f}"):
            st["why"] = "handover"
            log(f"{svc}: asked {peer} to hand it over: going home")


def hand_over():
    """The holder's side: stop, last copy, mark done; or give up."""
    nodes = state.get("nodes")
    if not nodes or NODE not in nodes:
        return
    now = time.time()
    mine = nodes[NODE]
    for svc, s in cfg["services"].items():
        req = annotation(mine, HANDOVER + svc)
        holder = state["labels"].get(PREFIX + svc) == "active"
        h = handing.get(svc)
        if not req or not holder or stateless(svc):
            if h:
                # Taken over (or withdrawn): back to normal.
                handing.pop(svc)
                try:
                    os.remove(os.path.join(SRC_DIR, svc))
                except FileNotFoundError:
                    pass
                if not holder:
                    log(f"{svc}: handed over to {s['peer']}")
                else:
                    log(f"{svc}: handover withdrawn, open here again")
            continue
        home, asked = req.split()[0], float(req.split()[1])
        if h is None or h["asked"] != asked:
            h = handing[svc] = {"asked": asked, "phase": "stop"}
            log(f"{svc}: {home} asked for it; stopping it here for a last copy")
        peer = nodes.get(home)
        if home != s["peer"] or peer is None or not ready(peer)[0] or now - asked > cfg["handover_timeout"] + 60:
            annotate(NODE, f"{HANDOVER}{svc}-", f"{HANDED}{svc}-")
            log(f"{svc}: giving up the handover to {home} (gone, or too long); opening it here again")
            continue
        if h["phase"] == "stop":
            # allowed() is false while handing over, so the round's fence has
            # killed its containers and taken the folder from /srv/ha.
            if os.path.isdir(ha_path(svc)) or is_mounted(ha_path(svc)) or containers_using(ha_path(svc)):
                continue
            h["phase"] = "copy-wait"
        if h["phase"] == "copy-wait":
            u = unit(svc)
            if u.get("ActiveState") in ("active", "activating", "deactivating"):
                continue  # a copy from before the stop; the last one starts after it
            os.makedirs(SRC_DIR, exist_ok=True)
            with open(os.path.join(SRC_DIR, svc), "w") as f:
                f.write(data(svc))
            h["inv"] = u.get("InvocationID", "")
            r = run("systemctl", "start", "--no-block", f"standby-copy-{svc}.service")
            if r.returncode != 0:
                log(f"{svc}: couldn't start the last copy: {r.stderr.strip()}")
                annotate(NODE, f"{HANDOVER}{svc}-")
                continue
            h["phase"] = "copying"
            log(f"{svc}: last copy to {home} started")
            continue
        if h["phase"] == "copying":
            u = unit(svc)
            if u.get("InvocationID", "") == h["inv"] or u.get("ActiveState") not in ("inactive", "failed"):
                continue
            if u.get("Result") == "success":
                annotate(NODE, f"{HANDED}{svc}={now:.0f}")
                h["phase"] = "done"
                log(f"{svc}: last copy is on {home}; it can take over")
            else:
                annotate(NODE, f"{HANDOVER}{svc}-")
                log(f"{svc}: the last copy failed ({u.get('Result')}); handover off, opening it here again")


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
    if placed:
        # From the node each database belongs on: how long its primary has
        # been elsewhere (0 when it's here). PlacementDrift alerts on it.
        lines += [
            "# HELP site_failover_out_of_place_seconds How long a database's primary has been away from where it belongs (this node).",
            "# TYPE site_failover_out_of_place_seconds gauge",
        ]
        now = time.time()
        for (ns, name), st in sorted(placed.items()):
            out = now - st["since"] if st.get("since") else 0
            lines.append(f'site_failover_out_of_place_seconds{{kind="database",name="{ns}/{name}",how="{st.get("how")}",'
                         f'at="{st.get("where") or ""}",action="{st.get("action")}"}} {out:.0f}')
    homes = {svc: st for svc, st in homing.items() if cfg["services"][svc].get("initial")}
    if homes:
        if not placed:
            lines += [
                "# HELP site_failover_out_of_place_seconds How long a database's primary has been away from where it belongs (this node).",
                "# TYPE site_failover_out_of_place_seconds gauge",
            ]
        now = time.time()
        for svc, st in sorted(homes.items()):
            out = now - st["since"] if st.get("since") else 0
            why = (st.get("why") or "ok").split(" ")[0] if out else "ok"
            at = ",".join(holders_of(state.get("nodes") or {}, svc)) if out else NODE
            lines.append(f'site_failover_out_of_place_seconds{{kind="service",name="{svc}",how="home",'
                         f'at="{at}",action="{why}"}} {out:.0f}')
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
        began = time.time()
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
            place()
        except Exception as e:
            log(f"placement: {e}")
        for step in (hand_over, go_home):
            try:
                step()
            except Exception as e:
                log(f"going home: {e}")
        write_metrics()
        took = time.time() - began
        if took > 30:
            # A round should take a few seconds; a slow cluster API makes
            # everything here late (failover, fencing, handovers).
            warn("round", "slow", f"a round took {took:.0f} s")
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


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    for address in cfg["listen"][1:]:
        threading.Thread(target=serve, args=(address,), daemon=True).start()
    serve(cfg["listen"][0])
