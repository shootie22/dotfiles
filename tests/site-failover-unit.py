"""Unit tests for site-failover's decisions (modules/nixos/site-failover).

  nix build .#checks.x86_64-linux.site-failover-unit -L

No VMs, a second. The VM test (tests/site-failover.nix) runs the real thing;
this covers the cases a VM can't easily stage:
- a holder that's up but can't run the service (infrastructure incident
  2026-10-20): which Pending pods count as stuck there
- placement (infrastructure docs/ha/decisions.md, 2026-10-21): where each
  database's primary belongs, when it's moved, and which pods are strays
"""

import importlib.util
import json
import os
import sys
import tempfile

cfg = {
    "node": "fuji", "k3s": ["k3s"], "cnpg_cli": ["kubectl-cnpg"], "port": 0, "interval": 5,
    "listen": ["127.0.0.1"], "fail_after": 10, "api_grace": 45, "unfit_after": 120, "hold_down": 1800,
    "home_window": "03:00-06:00", "home_fit_for": 1800, "home_every": 3600, "handover_timeout": 600,
    "services": {
        "gitea": {"peer": "thinkcentre", "initial": False, "data": "/x", "stateless": False, "cnpg": None,
                  "incoming": None, "receive": "/srv/standby/thinkcentre/gitea"},
        "matrix": {"peer": "thinkcentre", "initial": True, "data": "/y", "stateless": False,
                   "cnpg": {"namespace": "matrix", "clusters": ["synapse-db"]},
                   "incoming": None, "receive": "/srv/standby/thinkcentre/matrix"},
    },
}
f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
json.dump(cfg, f)
f.close()
sys.argv = ["site-failover", f.name]
spec = importlib.util.spec_from_file_location("sf", os.environ["SITE_FAILOVER"])
sf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sf)

failures = []


def check(name, got, want):
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))
    if not ok:
        failures.append(name)


T = "2026-10-20T20:35:00Z"
t = sf.ts(T)


def node(name, zone, labels=None):
    return {"metadata": {"name": name, "labels": {"topology.kubernetes.io/zone": zone, **(labels or {})}},
            "status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": T}]}}


NODES = {
    "fuji": node("fuji", "ro", {"ha.radunenu.com/matrix": "active"}),
    "thinkcentre": node("thinkcentre", "dk", {"ha.radunenu.com/gitea": "active"}),
    "minima": node("minima", "ro"),
}


def cluster(ns, name, ann=None, primary="x-1", phase=sf.HEALTHY, target=None):
    return {"metadata": {"namespace": ns, "name": name, "annotations": ann or {}},
            "status": {"currentPrimary": primary, "targetPrimary": target or primary, "phase": phase}}


def inst(name, node_name, ready=True):
    return {"metadata": {"name": name, "namespace": "ns", "labels": {}},
            "spec": {"nodeName": node_name},
            "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}}


# Where a primary belongs ---------------------------------------------------
INST = [inst("x-1", "fuji"), inst("x-2", "thinkcentre")]
legacy = sf.legacy_follows()
check("follows a service: its holder", sf.db_target(cluster("gitea", "gitea-pg", {sf.FOLLOWS: "gitea"}), INST, NODES, legacy)[0], "thinkcentre")
check("follows a service nobody holds: can't say", sf.db_target(cluster("a", "b", {sf.FOLLOWS: "nobody"}), INST, NODES, legacy)[0], None)
two = dict(NODES, minima=node("minima", "ro", {"ha.radunenu.com/gitea": "active"}))
check("follows a service two nodes hold: can't say", sf.db_target(cluster("gitea", "gitea-pg", {sf.FOLLOWS: "gitea"}), INST, two, legacy)[0], None)
check("home ro: the instance in RO", sf.db_target(cluster("keycloak", "keycloak-db", {sf.HOME: "ro"}), INST, NODES, legacy)[0], "fuji")
check("home dk: the instance in DK", sf.db_target(cluster("k", "k", {sf.HOME: "dk"}), INST, NODES, legacy)[0], "thinkcentre")
check("home with no instance there: can't say", sf.db_target(cluster("k", "k", {sf.HOME: "dk"}), [inst("x-1", "fuji")], NODES, legacy)[0], None)
check("the module's cnpg option still counts as follows", sf.db_target(cluster("matrix", "synapse-db"), INST, NODES, legacy)[:2], ("fuji", "follows"))
check("an annotation wins over the module's option", sf.db_target(cluster("matrix", "synapse-db", {sf.HOME: "dk"}), INST, NODES, legacy)[:2], ("thinkcentre", "home"))
check("nothing declared: nobody moves it", sf.db_target(cluster("a", "b"), INST, NODES, legacy)[0], None)


# When it's moved -----------------------------------------------------------
def move(c, target="fuji", how="home", busy=None, me_ok=True, st=None, now=t):
    st = st if st is not None else {"since": None, "last": 0.0}
    return sf.db_move(c, INST, target, how, busy, me_ok, st, now)[0], st


check("primary already here", move(cluster("k", "k", primary="x-1"))[0], "ok")
a, st = move(cluster("k", "k", primary="x-2"))
check("primary elsewhere, just noticed: wait", a, "wait")
check("  and it starts counting", st["since"], t)
check("home: still waiting after 60 s", move(cluster("k", "k", primary="x-2"), st=dict(st), now=t + 60)[0], "wait")
check("home: moved after 120 s", move(cluster("k", "k", primary="x-2"), st=dict(st), now=t + 121)[0], "promote")
check("follows: moved after 60 s", move(cluster("k", "k", primary="x-2"), how="follows", st=dict(st), now=t + 61)[0], "promote")
check("never while this cluster is switching over", move(cluster("k", "k", primary="x-2", target="x-1"), st=dict(st), now=t + 999)[0], "wait")
check("never while it isn't healthy", move(cluster("k", "k", primary="x-2", phase="Waiting for the instances to become active"), st=dict(st), now=t + 999)[0], "wait")
check("busy: a switchover underway", sf.moving(cluster("k", "k", primary="x-2", target="x-1")), True)
check("busy: failing over", sf.moving(cluster("k", "k", phase="Failing over")), True)
check("busy: merely unhealthy doesn't hold others up", sf.moving(cluster("k", "k", phase="Waiting for the instances to become active")), False)
check("never while another cluster is switching over", move(cluster("k", "k", primary="x-2"), busy="gitea/gitea-pg", st=dict(st), now=t + 999)[0], "wait")
failing = [cluster("a", "ok"), cluster("games", "games-pg", phase="Failing over"), cluster("gitea", "gitea-pg", primary="x-2", target="x-1")]
sf.moving_since.clear()
check("busy with the first cluster that's moving", sf.busy_with(failing, t), "games/games-pg")
check("  still after ten minutes", sf.busy_with(failing, t + 600), "games/games-pg")
check("  a move stuck for longer no longer holds the others up", sf.busy_with(failing, t + sf.STUCK), None)
check("  one that starts later still does", sf.busy_with(failing + [cluster("m", "mealie-pg", phase="Switchover in progress")], t + sf.STUCK + 5), "m/mealie-pg")
check("  nothing moving: nothing to wait for", sf.busy_with([cluster("a", "ok")], t + sf.STUCK + 10), None)
check("  and a cluster that moves again later counts from then", sf.busy_with(failing, t + sf.STUCK + 20), "games/games-pg")
sf.moving_since.clear()
check("never onto a node under pressure", move(cluster("k", "k", primary="x-2"), me_ok=False, st=dict(st), now=t + 999)[0], "wait")
check("home: not again within an hour", move(cluster("k", "k", primary="x-2"), st={"since": t, "last": t + 100}, now=t + 1000)[0], "wait")
check("home: again after an hour", move(cluster("k", "k", primary="x-2"), st={"since": t, "last": t}, now=t + 3601)[0], "promote")
st_new = {"since": None, "last": 0.0}
move(cluster("k", "k", primary="x-2", phase="Setting up primary"), st=st_new, now=t)
check("a cluster being made doesn't start the wait", st_new["since"], None)
check("  but counts as away for the alert", st_new["away"], t)
check("  and once healthy it waits the full time", move(cluster("k", "k", primary="x-2"), st=st_new, now=t + 300)[0], "wait")
check("  then moves", move(cluster("k", "k", primary="x-2"), st=st_new, now=t + 300 + 121)[0], "promote")
check("no ready instance here: wait", sf.db_move(cluster("k", "k", primary="x-2"), [inst("x-1", "fuji", ready=False), inst("x-2", "thinkcentre")],
                                                 "fuji", "home", None, True, {"since": t, "last": 0.0}, t + 999)[0], "wait")


# Pods left behind by a label that moved -------------------------------------
def pod(name, node_name, sel=None, aff=None, owner="ReplicaSet", phase="Running"):
    spec = {"nodeName": node_name}
    if sel:
        spec["nodeSelector"] = sel
    if aff:
        spec["affinity"] = {"nodeAffinity": aff}
    return {"metadata": {"name": name, "namespace": "rybbit", "ownerReferences": [{"kind": owner}]},
            "spec": spec, "status": {"phase": phase}}


req = {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [
    {"matchExpressions": [{"key": "ha.radunenu.com/rybbit-clickhouse", "operator": "In", "values": ["active"]}]}]}}
pref = {"preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 1, "preference": {"matchExpressions": [
    {"key": "ha.radunenu.com/rybbit-clickhouse", "operator": "In", "values": ["active"]}]}}]}
sel = {"ha.radunenu.com/rybbit-clickhouse": "active"}
check("requires: nodeSelector", sf.requires_label(pod("a", "x", sel=sel), "rybbit-clickhouse"), True)
check("requires: required node affinity", sf.requires_label(pod("a", "x", aff=req), "rybbit-clickhouse"), True)
check("requires: preferred only doesn't count", sf.requires_label(pod("a", "x", aff=pref), "rybbit-clickhouse"), False)
check("requires: another service's label", sf.requires_label(pod("a", "x", sel=sel), "rybbit"), False)
PODS = [pod("left", "fuji", sel=sel), pod("home", "thinkcentre", sel=sel), pod("job", "fuji", sel=sel, owner="Job"),
        pod("free", "fuji"), pod("pending", None, sel=sel, phase="Pending")]
check("strays: only the one left on another node", [p["metadata"]["name"] for p in sf.strays(PODS, "rybbit-clickhouse", "thinkcentre")], ["left"])


# A holder that's up but can't run the service --------------------------------
def pend(name, sched, node_name=None, waiting=None, owner="ReplicaSet", key="ha.radunenu.com/gitea", labels=None):
    conds = [{"type": "PodScheduled", "status": "True" if sched is True else "False",
              "reason": None if sched is True else sched, "lastTransitionTime": T}]
    cs = [{"state": {"waiting": {"reason": waiting}}}] if waiting else []
    return {"metadata": {"name": name, "namespace": "gitea", "labels": labels or {"app": "gitea", "pod-template-hash": name},
                         "ownerReferences": [{"kind": owner}]},
            "spec": {"nodeName": node_name, "nodeSelector": {key: "active"}},
            "status": {"phase": "Pending", "conditions": conds, "containerStatuses": cs}}


class P(sf.Pods):
    def __init__(self, pending, running):
        super().__init__()
        self.pending = pending
        self._running = running

    def get(self, *a):
        return self._running


def stuck(pending, running=()):
    got = sf.unfit("gitea", "thinkcentre", P(pending, list(running)))
    return None if got is None else round(got[1] - t)


running = {"metadata": {"name": "old", "namespace": "gitea", "labels": {"app": "gitea", "pod-template-hash": "old"},
                        "ownerReferences": [{"kind": "ReplicaSet"}]}, "spec": {"nodeName": "thinkcentre"},
           "status": {"phase": "Running"}}
check("stuck: unschedulable with nothing running", stuck([pend("a", "Unschedulable")]), 0)
check("stuck: not while the workload still runs (a rollout)", stuck([pend("a", "Unschedulable")], [running]), None)
check("stuck: an agent running doesn't hide the main pod", stuck([pend("a", "Unschedulable")], [dict(running, metadata=dict(running["metadata"], labels={"app": "agent"}))]), 0)
check("stuck: not for an image that won't pull", stuck([pend("a", True, "thinkcentre", "ImagePullBackOff")]), None)
check("stuck: never started gets 10 more minutes", stuck([pend("a", True, "thinkcentre", "ContainerCreating")]), 600)
check("stuck: not for a pod on another node", stuck([pend("a", True, "fuji")]), None)
check("stuck: not for a Job's pod", stuck([pend("a", "Unschedulable", owner="Job")]), None)
check("stuck: not for another service's pod", stuck([pend("a", "Unschedulable", key="ha.radunenu.com/gitea-x")]), None)

# Going home ----------------------------------------------------------------
import time as _t
def at(hh, mm):
    lt = list(_t.localtime(t)); lt[3], lt[4], lt[5] = hh, mm, 0
    return _t.mktime(_t.struct_time(lt))


check("window: 04:00 is inside 03:00-06:00", sf.in_window(at(4, 0), "03:00-06:00"), True)
check("window: 06:00 is outside", sf.in_window(at(6, 0), "03:00-06:00"), False)
check("window: across midnight, 23:30 in 23:00-02:00", sf.in_window(at(23, 30), "23:00-02:00"), True)
check("window: across midnight, 12:00 not in 23:00-02:00", sf.in_window(at(12, 0), "23:00-02:00"), False)

HOME = dict(cfg["services"]["matrix"], initial=True)
long_ago = "2026-10-19T00:00:00Z"
def hnodes(holder="thinkcentre", extra=None, fit_since=long_ago):
    n = {
        "fuji": {"metadata": {"name": "fuji", "labels": {}, "annotations": {}},
                 "status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": fit_since}]}},
        "thinkcentre": {"metadata": {"name": "thinkcentre", "labels": {"ha.radunenu.com/matrix": "active"}, "annotations": {}},
                        "status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": long_ago}]}},
    }
    if holder == "fuji":
        n["fuji"]["metadata"]["labels"]["ha.radunenu.com/matrix"] = "active"
        n["thinkcentre"]["metadata"]["labels"] = {}
    for k, v in (extra or {}).items():
        n[k]["metadata"]["annotations"].update(v)
    return n


night = at(4, 0)
def blocker(nodes, st=None, fresh=True, copy_ok=True, now=night, s=HOME):
    return sf.home_blocker("matrix", s, nodes, now, st or {"last": 0.0}, fresh, copy_ok)


check("home: goes in the quiet hours", blocker(hnodes()), None)
check("home: waits for the quiet hours", blocker(hnodes(), now=at(14, 0)), "quiet-hours")
check("home: not when it isn't the home", blocker(hnodes(), s=dict(HOME, initial=False)), "not its home")
check("home: not when set to stay", blocker(hnodes(), s=dict(HOME, go_home=False)), "not its home")
check("home: already home", blocker(hnodes(holder="fuji")), "not held by the peer alone")
check("home: not without the cluster", blocker(hnodes(), fresh=False), "can't reach the cluster")
check("home: not without a whole copy", blocker(hnodes(), copy_ok=False), "no whole copy here")
check("home: not before it's been fit 30 minutes", (blocker(hnodes(fit_since=_t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime(night - 600)))) or "").startswith("this node has been fit"), True)
check("home: not within an hour of the last move", blocker(hnodes(), st={"last": night - 600}), "moved within the last hour")
check("home: not the night a handover failed", blocker(hnodes(), st={"last": 0.0, "failed": night - 3600}), "the last handover failed; next quiet hours")
check("home: one handover at a time", (blocker(hnodes(extra={"thinkcentre": {sf.HANDOVER + "gitea": "fuji 1"}})) or "").startswith("a handover is under way"), True)
check("home: a done mark alone isn't a handover", blocker(hnodes(extra={"thinkcentre": {sf.HANDED + "gitea": "1"}})), None)
sick = hnodes()
sick["thinkcentre"]["status"]["conditions"].append({"type": "DiskPressure", "status": "True", "lastTransitionTime": T})
check("home: never while a node is under pressure", blocker(sick), "thinkcentre isn't fit")

# The home node's side of a handover, with the cluster stubbed out.
calls = []
sf.annotate = lambda node, *kv: calls.append(("annotate", node) + kv) or True
sf.claim = lambda svc, old, why=None: calls.append(("claim", svc, old))
sf.delete_strays = lambda svc, peer: calls.append(("strays", svc, peer))
sf.has_copy = lambda svc: True
sf.state.update(api_ok_at=_t.time(), labels={})
sf.cfg["services"] = {"matrix": dict(HOME)}
sf.cfg["home_window"] = "00:00-23:59"


def home_round(nodes):
    calls.clear()
    sf.state["nodes"] = nodes
    sf.go_home()
    return list(calls)


sf.homing.clear()
first = home_round(hnodes())
check("go home: asks the holder", [c[:2] for c in first], [("annotate", "thinkcentre")])
check("go home: remembers asking", sf.homing["matrix"].get("asked") is not None, True)
asked = sf.homing["matrix"]["asked"]
pending = hnodes(extra={"thinkcentre": {sf.HANDOVER + "matrix": f"fuji {asked:.0f}"}})
check("go home: waits while the holder copies", home_round(pending), [])
withdrawn = home_round(hnodes())
check("go home: a withdrawn handover isn't asked again", withdrawn, [])
check("go home: and it counts as failed", sf.homing["matrix"].get("failed") is not None, True)
check("go home: still nothing the round after", home_round(hnodes()), [])
sf.homing.clear()
home_round(hnodes())
asked = sf.homing["matrix"]["asked"]
done = hnodes(extra={"thinkcentre": {sf.HANDOVER + "matrix": f"fuji {asked:.0f}", sf.HANDED + "matrix": f"{asked + 5:.0f}"}})
got = home_round(done)
check("go home: takes over once the last copy is there", [c[0] for c in got], ["claim", "annotate", "strays"])

# Home already, with our request still on the peer (2026-11-18).
stale = hnodes(holder="fuji", extra={"thinkcentre": {sf.HANDOVER + "matrix": "fuji 1", sf.HANDED + "matrix": "2"}})
check("go home: a leftover request is cleared once it's here", home_round(stale),
      [("annotate", "thinkcentre", sf.HANDOVER + "matrix-", sf.HANDED + "matrix-")])
check("go home: a leftover done mark alone is cleared too", home_round(hnodes(holder="fuji", extra={"thinkcentre": {sf.HANDED + "matrix": "2"}})),
      [("annotate", "thinkcentre", sf.HANDED + "matrix-")])
check("go home: another node's request is left alone", home_round(hnodes(holder="fuji", extra={"thinkcentre": {sf.HANDOVER + "matrix": "dell 1"}})), [])
check("go home: nothing to clear, nothing done", home_round(hnodes(holder="fuji")), [])

# Nobody holds it (2026-11-18): a move in the middle, or one that stopped.
class R:
    def __init__(self, out=""):
        self.returncode, self.stdout, self.stderr = 0, out, ""

def unheld_nodes():
    fj = {"metadata": {"name": "fuji", "labels": {}, "annotations": {}},
          "status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": long_ago}]}}
    tc = {"metadata": {"name": "thinkcentre", "labels": {}, "annotations": {}},
          "status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": long_ago}]}}
    return {"items": [fj, tc]}

def unheld_tick(when):
    calls.clear()
    sf.kubectl = lambda *a: R(json.dumps(unheld_nodes())) if a[:2] == ("get", "nodes") else R()
    sf.cfg["services"] = {"matrix": dict(cfg["services"]["matrix"], initial=True)}
    sf.data = lambda svc: "/y"
    real = _t.time
    sf.time.time = lambda: when
    try:
        sf.tick()
    finally:
        sf.time.time = real
    return [c for c in calls if c[0] == "claim"]

sf.unheld_since.clear()
t1 = _t.time()
check("unheld: not claimed the moment nobody holds it (a move in the middle)", unheld_tick(t1), [])
check("unheld: nor 20 s later", unheld_tick(t1 + 20), [])
check("unheld: claimed once nobody has held it for UNHELD_WAIT", unheld_tick(t1 + sf.UNHELD_WAIT + 1), [("claim", "matrix", None)])
sf.unheld_since.clear()
unheld_tick(t1)
sf.unheld_since.pop("matrix", None)  # someone held it in between
check("unheld: the wait starts over after someone held it", unheld_tick(t1 + sf.UNHELD_WAIT + 1), [])

# A planned k3s restart (2026-11-18) ------------------------------------------
check("planned: this node stops well before the other may start (a minute of clock skew to spare)",
      sf.PLANNED_LOCAL + 60 < sf.PLANNED_PEER, True)
sf.PLANNED_FILE = os.path.join(tempfile.mkdtemp(), "planned-restart")
now = _t.time()
check("planned here: no notice, nothing", sf.planned_here(now), None)
with open(sf.PLANNED_FILE, "w") as f:
    f.write(f"{now - 30:.0f}\n")
check("planned here: a notice 30 s old counts", sf.planned_here(now) is not None, True)
check("planned here: not after PLANNED_LOCAL", sf.planned_here(now + sf.PLANNED_LOCAL), None)
sf.state["api_ok_at"] = now - 100
check("api: lost after api_grace without a notice", sf.api_fresh(now + sf.PLANNED_LOCAL), False)
check("api: still fresh during a planned restart", sf.api_fresh(now), True)
with open(sf.PLANNED_FILE, "w") as f:
    f.write("rubbish")
check("planned here: an unreadable notice doesn't count", sf.planned_here(now), None)
os.remove(sf.PLANNED_FILE)
check("api: and without it, lost again", sf.api_fresh(now), False)

def ann(at):
    return {"metadata": {"annotations": {sf.PLANNED: f"{at:.0f}"}}}
check("planned peer: a fresh notice counts", sf.planned_peer(ann(now - 30), now) is not None, True)
check("planned peer: not after PLANNED_PEER", sf.planned_peer(ann(now - sf.PLANNED_PEER - 1), now), None)
check("planned peer: not from the future", sf.planned_peer(ann(now + 120), now), None)
check("planned peer: a little clock skew is fine", sf.planned_peer(ann(now + 30), now) is not None, True)
check("planned peer: no notice", sf.planned_peer({"metadata": {}}, now), None)
check("planned peer: rubbish", sf.planned_peer({"metadata": {"annotations": {sf.PLANNED: "x"}}}, now), None)

# The other node's side: tick() with the cluster stubbed out. fuji is this
# node, the thinkcentre holds gitea and has been NotReady for a while.
def tnodes(notice=None, ready="False"):
    tc = {"metadata": {"name": "thinkcentre", "labels": {"ha.radunenu.com/gitea": "active"}, "annotations": {}},
          "status": {"conditions": [{"type": "Ready", "status": ready,
                                     "lastTransitionTime": _t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime(_t.time() - 60))}]}}
    if notice is not None:
        tc["metadata"]["annotations"][sf.PLANNED] = f"{notice:.0f}"
    fj = {"metadata": {"name": "fuji", "labels": {}, "annotations": {}},
          "status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": long_ago}]}}
    return {"items": [fj, tc]}

def tick_with(nodes_json):
    calls.clear()
    sf.kubectl = lambda *a: (calls.append(("kubectl",) + a) or R(json.dumps(nodes_json))) if a[:2] == ("get", "nodes") else (calls.append(("kubectl",) + a) or R())
    sf.cfg["services"] = {"gitea": dict(cfg["services"]["gitea"])}
    sf.data = lambda svc: "/x"
    sf.seen.clear()
    sf.tick()
    return [c for c in calls if c[0] == "claim"]

check("takeover: a NotReady holder without a notice is taken over", tick_with(tnodes()), [("claim", "gitea", "thinkcentre")])
check("takeover: not while it announced a planned k3s restart", tick_with(tnodes(notice=_t.time() - 60)), [])
check("takeover: a notice older than PLANNED_PEER is ignored",
      tick_with(tnodes(notice=_t.time() - sf.PLANNED_PEER - 5)), [("claim", "gitea", "thinkcentre")])
check("takeover: a notice from the future is ignored", tick_with(tnodes(notice=_t.time() + 600)), [("claim", "gitea", "thinkcentre")])
stale_me = tnodes()
stale_me["items"][0]["metadata"]["annotations"][sf.PLANNED] = f"{_t.time() - 999:.0f}"
tick_with(stale_me)
check("tidy: this node's stale notice is removed", ("kubectl", "annotate", "node", "fuji", f"{sf.PLANNED}-") in calls, True)
fresh_me = tnodes()
fresh_me["items"][0]["metadata"]["annotations"][sf.PLANNED] = f"{_t.time() - 5:.0f}"
tick_with(fresh_me)
check("tidy: a fresh one stays", any(c[:2] == ("kubectl", "annotate") for c in calls), False)

# A switchover only to a replica that's streaming (2026-11-13: synapse-db was
# switched over seconds after its replica had dropped out).
class R:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


kc = []
answers = {}


def fake_kubectl(*args):
    kc.append(args)
    for k, v in answers.items():
        if k in " ".join(args):
            return v
    return R()


real_kubectl = sf.kubectl
sf.kubectl = fake_kubectl
answers = {"pg_stat_replication": R(out="streaming\n")}
check("switchover: a streaming replica is fine", sf.replica_streaming("matrix", "synapse-db-2", "synapse-db-1"), True)
check("switchover: asks the primary about that replica",
      kc[-1][:6] + (kc[-1][-1],), ("-n", "matrix", "exec", "synapse-db-2", "-c", "postgres",
                                   "SELECT state FROM pg_stat_replication WHERE application_name = 'synapse-db-1'"))
answers = {"pg_stat_replication": R(out="catchup\n")}
check("switchover: a replica catching up isn't", sf.replica_streaming("matrix", "a", "b"), False)
answers = {"pg_stat_replication": R(out="")}
check("switchover: a replica that isn't connected isn't", sf.replica_streaming("matrix", "a", "b"), False)
answers = {"pg_stat_replication": R(rc=1, err="exec failed")}
check("switchover: no answer from the primary isn't", sf.replica_streaming("matrix", "a", "b"), False)


# Restart after a primary change (placement.radunenu.com/restart-on-switch).
def sw_cluster(primary="synapse-db-2", when="2026-11-19T16:38:40Z", target=None, ann="deployment/synapse, deployment/mas"):
    return {"metadata": {"name": "synapse-db", "namespace": "matrix",
                         "annotations": {sf.RESTART_ON_SWITCH: ann} if ann else {}},
            "status": {"currentPrimary": primary, "targetPrimary": target or primary,
                       "currentPrimaryTimestamp": when, "phase": "Cluster in healthy state"}}


kc.clear()
answers = {"get deployment/synapse": R(out=""), "get deployment/mas": R(out="")}
check("restart: first look restarts nothing", sf.restart_after_switch(sw_cluster()), [])
check("restart: first look records the promotion",
      [a for a in kc if a[2] == "annotate"],
      [("-n", "matrix", "annotate", "deployment/synapse", "--overwrite", f"{sf.RESTARTED_FOR}=synapse-db-2 2026-11-19T16:38:40Z"),
       ("-n", "matrix", "annotate", "deployment/mas", "--overwrite", f"{sf.RESTARTED_FOR}=synapse-db-2 2026-11-19T16:38:40Z")])
kc.clear()
answers = {"get deployment": R(out="synapse-db-2 2026-11-19T16:38:40Z")}
check("restart: same promotion, nothing", sf.restart_after_switch(sw_cluster()), [])
check("restart: same promotion, no writes", [a for a in kc if a[2] in ("annotate", "rollout")], [])
kc.clear()
answers = {"get deployment": R(out="synapse-db-1 2026-11-13T01:15:20Z")}
check("restart: a new promotion restarts both", sf.restart_after_switch(sw_cluster()), ["deployment/synapse", "deployment/mas"])
check("restart: ...with rollout restart",
      [a for a in kc if a[2] == "rollout"],
      [("-n", "matrix", "rollout", "restart", "deployment/synapse"), ("-n", "matrix", "rollout", "restart", "deployment/mas")])
kc.clear()
check("restart: not while it's still switching over",
      sf.restart_after_switch(sw_cluster(target="synapse-db-1")), [])
check("restart: ...and nothing asked", kc, [])
check("restart: no annotation, nothing", sf.restart_after_switch(sw_cluster(ann=None)), [])
kc.clear()
answers = {"get deployment/synapse": R(out="synapse-db-1 x"), "rollout restart deployment/synapse": R(rc=1, err="forbidden"),
           "get deployment/mas": R(out="synapse-db-1 x")}
check("restart: a failed restart isn't recorded as done",
      ("-n", "matrix", "annotate", "deployment/synapse", "--overwrite", f"{sf.RESTARTED_FOR}=synapse-db-2 2026-11-19T16:38:40Z") in kc, False)
sf.restart_after_switch(sw_cluster())
check("restart: ...so the next look tries again",
      ("-n", "matrix", "annotate", "deployment/synapse", "--overwrite", f"{sf.RESTARTED_FOR}=synapse-db-2 2026-11-19T16:38:40Z") in kc, False)
sf.kubectl = real_kubectl

if failures:
    print(f"\n{len(failures)} failed")
    sys.exit(1)
print("\nall passed")
