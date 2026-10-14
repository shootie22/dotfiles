# Rehearsal of Phase 4 (infrastructure #28-#33): replicated Postgres with
# CloudNativePG, one instance per site, on the cluster as it is since Phase 3
# (etcd on fuji, the thinkcentre and the edge, everything over Nebula, RO and
# DK behind NAT).
#
#   nix build .#checks.x86_64-linux.cnpg-across-sites -L
#
# Steps:
#   1. the cluster up, nodes labelled by site, the operator with one copy
#      per site
#   2. a database cluster: the primary in one site, the replica in the other
#   3. the primary's pod deleted: the replica takes over
#   4. the primary's machine crashes: the replica takes over; when it's back
#      it rejoins as a replica
#   5. RO and DK cut off from each other: only the side with etcd's majority
#      (here RO, with the edge) keeps a primary, the cut-off one stops taking
#      writes, so there are never two; after the cut heals it rejoins
#   6. the dump job: pg_dump from the replica into a folder Borg backs up
#   7. the primary follows a service (site-failover's `cnpg`, Matrix): the
#      service's label goes to the replica's node, and the primary is
#      switched over there by itself
#   8. synchronous replication with dataDurability: preferred (Matrix's
#      databases): the replica's machine crashes and writes carry on
# Times are printed; they go into the journal (#33).
{ pkgs, k3sPackage }:

let
  lib = pkgs.lib;
  token = pkgs.writeText "k3s-token" "rehearsal-token";

  upstreamManifest = pkgs.fetchurl {
    url = "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml";
    hash = "sha256-NyN/FF2BOCVuolroMPh3WSVWZf8I+NVS/dgiSl7AMvs=";
  };
  # The operator as it will run for real: one copy per site, so losing a site
  # never takes the only one, and the image that's already there (the
  # upstream manifest says Always, which an offline VM can't do). Changed
  # before it's applied, so no pod ever starts with the upstream settings.
  operatorManifest = pkgs.runCommand "cnpg-operator.yaml" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
    yq '(select(.kind == "Deployment" and .metadata.name == "cnpg-controller-manager") | .spec) |= (
      .replicas = 2 |
      .template.spec.containers[0].imagePullPolicy = "IfNotPresent" |
      .template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
        { "topologyKey": "topology.kubernetes.io/zone",
          "labelSelector": { "matchLabels": { "app.kubernetes.io/name": "cloudnative-pg" } } } ]
    )' ${upstreamManifest} > $out
  '';
  operatorImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/cloudnative-pg/cloudnative-pg";
    imageDigest = "sha256:923c267ec29636db3bee20f993d0ec4973fa22998e1adad37da79e4d32b5bc07";
    hash = "sha256-RMFrp/WKFCRqya08mKu4CPTk2fPl0sgTXdSoVIr0sqA=";
    finalImageName = "ghcr.io/cloudnative-pg/cloudnative-pg";
    finalImageTag = "1.30.1";
  };
  postgresImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/cloudnative-pg/postgresql";
    imageDigest = "sha256:899d3ed526b659d77935dde0e6bf2d69dbbf17d3d8c6486ca8cfd04bd3c18533";
    hash = "sha256-MUg0z59t+RDJURrLElZgUQNPy1gwMMQGy90PtdDCzgo=";
    finalImageName = "ghcr.io/cloudnative-pg/postgresql";
    finalImageTag = "18.6";
  };

  # The database cluster: the pattern every HA service copies (#31).
  pgCluster = pkgs.writeText "pg.yaml" ''
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: pg
    spec:
      instances: 2
      imageName: ghcr.io/cloudnative-pg/postgresql:18.6
      imagePullPolicy: IfNotPresent
      storage:
        size: 1Gi
        storageClass: local-path
      affinity:
        enablePodAntiAffinity: true
        podAntiAffinityType: required
        topologyKey: topology.kubernetes.io/zone
        nodeSelector:
          db: "true"
      probes:
        liveness:
          isolationCheck:
            enabled: true
  '';

  # Hourly dump from the replica into a folder Borg backs up (#32).
  dumpJob = pkgs.writeText "dump.yaml" ''
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: pg-dump
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          nodeSelector:
            kubernetes.io/hostname: fuji
          containers:
            - name: dump
              image: ghcr.io/cloudnative-pg/postgresql:18.6
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-ec"]
              args:
                - pg_dump -h pg-ro -U app -d app -Fc -f /backup/app.dump && ls -l /backup
              env:
                - name: PGPASSWORD
                  valueFrom: { secretKeyRef: { name: pg-app, key: password } }
              volumeMounts:
                - { name: backup, mountPath: /backup }
          volumes:
            - name: backup
              hostPath: { path: /var/lib/pg-dumps, type: Directory }
  '';

  # Stand-in for sops-nix (as in tests/site-failover.nix); the service here
  # is stateless, so nothing is copied and no key is needed.
  sopsStub = {
    options.sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        freeformType = lib.types.attrs;
        options.path = lib.mkOption { type = lib.types.str; default = "/etc/standby-copy-key"; };
      });
      default = { };
    };
  };

  etcdctl = pkgs.writeShellScriptBin "etcdctl-k3s" ''
    d=/var/lib/rancher/k3s/server/tls/etcd
    exec ${pkgs.etcd}/bin/etcdctl --endpoints https://127.0.0.1:2379 \
      --cacert $d/server-ca.crt --cert $d/client.crt --key $d/client.key "$@"
  '';

  # Nebula, as in tests/etcd-over-nebula.nix ---------------------------------
  mesh = { edge = 1; fuji = 2; thinkcentre = 3; };
  meshIP = name: "10.99.0.${toString mesh.${name}}";
  certs = pkgs.runCommand "nebula-test-certs" { nativeBuildInputs = [ pkgs.nebula ]; } ''
    mkdir $out && cd $out
    nebula-cert ca -name rehearsal -duration 8760h
    ${lib.concatStrings (lib.mapAttrsToList (name: _: ''
      nebula-cert sign -name ${name} -ip ${meshIP name}/24 -groups servers
    '') mesh)}
  '';
  addr = node: iface: (lib.head node.networking.interfaces.${iface}.ipv4.addresses).address;
  isLighthouse = name: name == "edge" || name == "fuji";
  nebulaNode = name: { nodes, ... }: {
    services.nebula.networks.mesh = {
      enable = true;
      ca = "${certs}/ca.crt";
      cert = "${certs}/${name}.crt";
      key = "${certs}/${name}.key";
      isLighthouse = isLighthouse name;
      isRelay = isLighthouse name;
      lighthouses = lib.optionals (!isLighthouse name) [ (meshIP "edge") (meshIP "fuji") ];
      relays = lib.optionals (!isLighthouse name) [ (meshIP "edge") (meshIP "fuji") ];
      listen.port = if isLighthouse name then 4242 else 4241;
      staticHostMap = {
        ${meshIP "edge"} = [ "${addr nodes.edge "eth1"}:4242" ];
        ${meshIP "fuji"} = [ "${addr nodes.rorouter "eth2"}:4242" "${addr nodes.fuji "eth1"}:4242" ];
      };
      settings.punchy = { punch = true; respond = true; };
      firewall = {
        outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
        inbound = [ { port = "any"; proto = "any"; group = "servers"; } ];
      };
    };
    # As in modules/nixos/nebula-mesh.nix: an API server leaves itself out.
    networking.hosts = lib.mkMerge (map (s: { ${meshIP s} = [ "k3s-api" ]; })
      (lib.filter (s: s != name) [ "fuji" "thinkcentre" ]));
  };

  siteVlan = { edge = 100; fuji = 1; thinkcentre = 2; };
  router = lanVlan: forward: { ... }: {
    virtualisation.vlans = [ lanVlan 100 ];
    virtualisation.memorySize = 384;
    networking.firewall.enable = false;
    networking.nat = {
      enable = true;
      internalInterfaces = [ "eth1" ];
      externalInterface = "eth2";
      extraCommands = lib.optionalString (forward != null)
        "iptables -w -t nat -A nixos-nat-pre -i eth2 -p udp --dport 4242 -j DNAT --to-destination ${forward}:4242";
    };
  };

  # The real servers' k3s flags since Phase 3 (hosts/fuji/configuration.nix).
  serverFlags = name: [
    "--node-ip=${meshIP name}" "--node-external-ip=${meshIP name}" "--advertise-address=${meshIP name}"
    "--tls-san=k3s-api" "--egress-selector-mode=disabled" "--flannel-backend=wireguard-native"
    "--flannel-iface=nebula.mesh" "--flannel-external-ip"
  ];
  zone = { fuji = "ro"; thinkcentre = "dk"; edge = "edge"; };

  peerOf = { fuji = "thinkcentre"; thinkcentre = "fuji"; };
  k3sNode = name: { config, nodes, ... }: {
    imports = [ (nebulaNode name) ] ++ lib.optionals (name != "edge")
      [ ../modules/nixos/standby-copy.nix ../modules/nixos/site-failover sopsStub ];
    virtualisation = { memorySize = 3072; cores = 2; diskSize = 8192; };
    virtualisation.vlans = [ siteVlan.${name} ];
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.kubectl pkgs.jq pkgs.iptables etcdctl ];
    environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    networking.defaultGateway = lib.mkIf (name != "edge")
      (addr nodes.${if name == "fuji" then "rorouter" else "dkrouter"} "eth1");
    services.k3s = {
      enable = true;
      package = k3sPackage;
      role = "server";
      tokenFile = token;
      clusterInit = name == "fuji";
      serverAddr = lib.mkIf (name != "fuji") "https://k3s-api:6443";
      images = [ k3sPackage."airgap-images-amd64-tar-zst" operatorImage postgresImage ];
      extraFlags = serverFlags name ++ [ "--node-label=topology.kubernetes.io/zone=${zone.${name}}" ]
        ++ lib.optionals (name != "edge") [ "--node-label=db=true" ]
        ++ lib.optionals (name == "edge") [
          "--disable-apiserver" "--disable-controller-manager" "--disable-scheduler"
          "--node-taint=node-role.kubernetes.io/etcd=true:NoExecute"
        ];
    };
    systemd.services.k3s = { after = [ "nebula@mesh.service" ]; wants = [ "nebula@mesh.service" ]; };
    # Where the dump job writes (Borg backs it up); owned by the postgres
    # image's user, as the real host config will do.
    systemd.tmpfiles.rules = [ "d /var/lib/pg-dumps 0700 26 26 -" ];
  } // lib.optionalAttrs (name != "edge") {
    # A service whose database follows it, like Matrix (step 7). Stateless:
    # only its label matters here. Nobody holds it until the test sets it.
    dotfiles.standbyCopy = {
      publicKeys = { fuji = "ssh-ed25519 PLACEHOLDER"; thinkcentre = "ssh-ed25519 PLACEHOLDER"; };
      receive = { enable = true; dir = "/srv/standby"; from = [ ]; };
    };
    dotfiles.siteFailover.services.app = {
      stateless = true;
      peer = peerOf.${name};
      cnpg = { namespace = "default"; clusters = [ "pg" ]; };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "cnpg-across-sites";

  nodes = {
    rorouter = { nodes, ... }: { imports = [ (router 1 (addr nodes.fuji "eth1")) ]; };
    dkrouter = { ... }: { imports = [ (router 2 null) ]; };
    fuji = k3sNode "fuji";
    thinkcentre = k3sNode "thinkcentre";
    edge = k3sNode "edge";
  };

  testScript = ''
    import time

    def api(timeout=600):
        end = time.time() + timeout
        while time.time() < end:
            for m in (fuji, thinkcentre):
                if m.execute("kubectl get --raw /readyz >/dev/null 2>&1")[0] == 0:
                    return m
            time.sleep(3)
        raise Exception("no API")

    def primary(via=None):
        return (via or api()).succeed("kubectl get cluster pg -o jsonpath={.status.currentPrimary}").strip()

    def where(pod, via=None):
        return (via or api()).succeed(f"kubectl get pod {pod} -o jsonpath={{.spec.nodeName}}").strip()

    def sql(q, via=None, pod=None):
        a = via or api()
        p = pod or primary(a)
        return a.succeed(f"kubectl exec {p} -c postgres -- psql -U postgres -d app -tAc \"{q}\"").strip()

    def wait_writable(via=None, timeout=600):
        # Writes work again: through whichever pod is primary now.
        t0 = time.time()
        a = via or api()
        a.wait_until_succeeds(
            "p=$(kubectl get cluster pg -o jsonpath={.status.currentPrimary}) && "
            "kubectl exec $p -c postgres -- psql -U postgres -d app -tAc \"insert into t values (now()) returning 1\"",
            timeout=timeout)
        return time.time() - t0

    with subtest("1. cluster, sites, operator in both sites"):
        for r in (rorouter, dkrouter):
            r.start()
        for r in (rorouter, dkrouter):
            r.wait_for_unit("nat.service")
        for m in (fuji, thinkcentre, edge):
            m.start()
        fuji.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 3 ]", timeout=900)
        api().wait_until_succeeds("kubectl get node thinkcentre | grep -w Ready", timeout=600)
        print(api().succeed("kubectl get nodes -L topology.kubernetes.io/zone,db"))
        a = api()
        a.succeed("kubectl apply --server-side -f ${operatorManifest}")
        a.wait_until_succeeds("kubectl -n cnpg-system rollout status deployment cnpg-controller-manager --timeout=10s", timeout=600)
        print(a.succeed("kubectl -n cnpg-system get pods -o wide"))

    with subtest("2. a database, one instance per site"):
        a = api()
        a.succeed("kubectl apply -f ${pgCluster}")
        a.wait_until_succeeds("kubectl get cluster pg -o jsonpath={.status.readyInstances} | grep -x 2", timeout=900)
        pods = a.succeed("kubectl get pods -l cnpg.io/cluster=pg -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName} {end}'").split()
        print("instances:", pods, "primary:", primary(a))
        assert len({p.split("=")[1] for p in pods}) == 2, pods
        # Owned by the app user, like a real app's tables (the dump runs as it).
        sql("create table t (at timestamptz); alter table t owner to app")
        sql("insert into t values (now())")

    with subtest("3. primary's pod deleted: the replica takes over"):
        a = api()
        old = primary(a)
        t0 = time.time()
        a.succeed(f"kubectl delete pod {old} --wait=false")
        a.wait_until_succeeds(f"p=$(kubectl get cluster pg -o jsonpath={{.status.currentPrimary}}) && [ \"$p\" != {old} ]", timeout=300)
        wait_writable(a)
        print(f"TIME pod delete: new primary {primary(a)}, writes again after ~{time.time() - t0:.0f} s")
        a.wait_until_succeeds("kubectl get cluster pg -o jsonpath={.status.readyInstances} | grep -x 2", timeout=600)

    with subtest("4. primary's machine crashes; it rejoins as a replica"):
        a = api()
        p = primary(a)
        node = where(p, a)
        victim = fuji if node == "fuji" else thinkcentre
        other = thinkcentre if victim is fuji else fuji
        t0 = time.time()
        victim.crash()
        other.wait_until_succeeds(f"p=$(kubectl get cluster pg -o jsonpath={{.status.currentPrimary}}) && [ \"$p\" != {p} ]", timeout=900)
        wait_writable(other)
        print(f"TIME machine crash ({node}): writes again after ~{time.time() - t0:.0f} s, primary {primary(other)}")
        victim.start()
        other.wait_until_succeeds("kubectl get cluster pg -o jsonpath={.status.readyInstances} | grep -x 2", timeout=900)
        print("rejoined:", other.succeed("kubectl get pods -l cnpg.io/cluster=pg -L cnpg.io/instanceRole -o wide"))

    with subtest("5. RO and DK cut off from each other: never two primaries"):
        a = api()
        # Make DK the primary's site, so the cut-off side is the one with it.
        if where(primary(a), a) != "thinkcentre":
            a.succeed("kubectl patch cluster pg --type merge -p '{\"spec\":{\"primaryUpdateMethod\":\"switchover\"}}'")
            target = a.succeed("kubectl get pods -l cnpg.io/cluster=pg -o json | jq -r '.items[] | select(.spec.nodeName==\"thinkcentre\") | .metadata.name'").strip()
            a.succeed(f"kubectl patch cluster pg --subresource status --type merge -p '{{\"status\":{{\"targetPrimary\":\"{target}\"}}}}'")
            a.wait_until_succeeds(f"kubectl get cluster pg -o jsonpath={{.status.currentPrimary}} | grep -x {target}", timeout=600)
            wait_writable(a)
        dk_primary = primary(a)
        print("primary before the cut:", dk_primary, "on", where(dk_primary, a))
        # The cut: DK's only way to the others is the mesh; drop it.
        t0 = time.time()
        thinkcentre.succeed("iptables -I INPUT -i nebula.mesh -j DROP; iptables -I OUTPUT -o nebula.mesh -j DROP")
        # RO keeps etcd's majority (fuji + edge) and promotes its replica.
        fuji.wait_until_succeeds(f"p=$(kubectl get cluster pg -o jsonpath={{.status.currentPrimary}}) && [ \"$p\" != {dk_primary} ]", timeout=900)
        wait_writable(fuji)
        print(f"TIME RO/DK cut: RO takes writes after ~{time.time() - t0:.0f} s")
        # The cut-off old primary must not take writes: it stops itself once
        # it can't reach the API (isolation check).
        thinkcentre.wait_until_fails(
            "c=$(k3s crictl ps --name postgres -q | head -1) && [ -n \"$c\" ] && "
            "k3s crictl exec $c psql -U postgres -d app -tAc \"select pg_is_in_recovery()\" | grep -x f",
            timeout=300)
        print(f"old primary in DK stopped taking writes after ~{time.time() - t0:.0f} s")
        thinkcentre.succeed("iptables -D INPUT -i nebula.mesh -j DROP; iptables -D OUTPUT -o nebula.mesh -j DROP")
        fuji.wait_until_succeeds("kubectl get cluster pg -o jsonpath={.status.readyInstances} | grep -x 2", timeout=900)
        rows = sql("select count(*) from t", via=fuji)
        print("after the cut healed: 2 instances ready, rows:", rows)

    with subtest("6. dump from the replica into a Borg-backed folder"):
        a = api()
        a.succeed("kubectl apply -f ${dumpJob}")
        try:
            a.wait_until_succeeds("kubectl get job pg-dump -o jsonpath={.status.succeeded} | grep -x 1", timeout=600)
        finally:
            print(a.execute("kubectl logs job/pg-dump 2>&1; kubectl describe job pg-dump | tail -5")[1])
        fuji.succeed("test -s /var/lib/pg-dumps/app.dump")
        print(fuji.succeed("ls -l /var/lib/pg-dumps"))

    with subtest("7. the primary follows the service to the replica's node"):
        a = api()
        a.wait_until_succeeds("kubectl get cluster pg -o jsonpath={.status.readyInstances} | grep -x 2", timeout=600)
        p = primary(a)
        here = "thinkcentre" if where(p, a) == "fuji" else "fuji"
        node = fuji if here == "fuji" else thinkcentre
        rows = sql("select count(*) from t", via=a)
        # Whoever holds the label now (site-failover gave it to fuji while
        # the thinkcentre was cut off in step 5): two holders must never move
        # the database.
        a.succeed("kubectl label node fuji thinkcentre ha.radunenu.com/app=active --overwrite")
        time.sleep(100)
        assert where(primary(a), a) != here, "the primary moved with two label holders"
        node.succeed("journalctl -u site-failover | grep -q 'not only by this node'")
        # Moved the way the runbook does: off every node, onto the new one.
        t0 = time.time()
        a.succeed("kubectl label node fuji thinkcentre ha.radunenu.com/app-")
        a.succeed(f"kubectl label node {here} ha.radunenu.com/app=active")
        # site-failover waits a minute of the primary staying elsewhere, then
        # switches over.
        node.wait_until_succeeds(
            f"p=$(kubectl get cluster pg -o jsonpath={{.status.currentPrimary}}) && "
            f"[ \"$(kubectl get pod $p -o jsonpath={{.spec.nodeName}})\" = {here} ]", timeout=420)
        wait_writable(node)
        print(f"TIME primary followed the service to {here} after ~{time.time() - t0:.0f} s")
        print(node.succeed("journalctl -u site-failover | grep -i 'switch' || true"))
        node.wait_until_succeeds(
            "grep -qx 'site_failover_db_elsewhere{service=\"app\",cluster=\"pg\"} 0' "
            "/var/lib/node-exporter-textfile/site_failover.prom", timeout=120)
        assert int(sql("select count(*) from t", via=node)) >= int(rows), "rows lost in the switchover"
        # No second switchover: the primary stays put.
        time.sleep(90)
        assert where(primary(node), node) == here, "the primary moved again"

    with subtest("8. synchronous, dataDurability preferred: the replica's machine crashes, writes carry on"):
        a = api()
        a.succeed("kubectl patch cluster pg --type merge -p "
                  "'{\"spec\":{\"postgresql\":{\"synchronous\":{\"method\":\"any\",\"number\":1,\"dataDurability\":\"preferred\"}}}}'")
        a.wait_until_succeeds("[ -n \"$(kubectl exec $(kubectl get cluster pg -o jsonpath={.status.currentPrimary}) -c postgres -- "
                              "psql -U postgres -tAc 'show synchronous_standby_names')\" ]", timeout=300)
        print("synchronous_standby_names:", sql("show synchronous_standby_names", via=a))
        p = primary(a)
        survivor_name = where(p, a)
        survivor = fuji if survivor_name == "fuji" else thinkcentre
        victim = thinkcentre if survivor is fuji else fuji
        t0 = time.time()
        victim.crash()
        # Writes on the primary must not hang waiting for the lost standby.
        survivor.wait_until_succeeds(
            f"timeout 10 kubectl exec {p} -c postgres -- psql -U postgres -d app -tAc "
            f"\"insert into t values (now()) returning 1\"", timeout=300)
        print(f"TIME replica's machine gone: writes on {survivor_name} work again after ~{time.time() - t0:.0f} s")
        victim.start()
        survivor.wait_until_succeeds("kubectl get cluster pg -o jsonpath={.status.readyInstances} | grep -x 2", timeout=900)
        print("replica back:", survivor.succeed("kubectl get pods -l cnpg.io/cluster=pg -L cnpg.io/instanceRole -o wide"))
  '';
}
