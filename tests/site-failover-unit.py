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

if failures:
    print(f"\n{len(failures)} failed")
    sys.exit(1)
print("\nall passed")
