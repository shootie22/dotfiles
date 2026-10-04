# Rehearsal of Phase 3 (infrastructure #20-#26): moving the cluster from
# SQLite on fuji to etcd across fuji, the thinkcentre and the edge, in VMs.
# Same k3s package and flannel backend as the real servers; latency between
# the VMs roughly like the real tailnet (fuji-thinkcentre 55 ms, fuji-edge
# 33 ms, thinkcentre-edge 13 ms, measured 2026-10-04).
#
#   nix build .#checks.x86_64-linux.etcd-migration -L
#
# Steps, as the real migration would go:
#   1. fuji on SQLite with a workload and some data
#   2. fuji switched to embedded etcd (--cluster-init): data still there
#   3. the thinkcentre joins as the second server, the edge as an etcd-only
#      member, mixi as an agent
#   4. fuji crashes: the cluster keeps working from the other two
#   5. fuji comes back and rejoins
#   6. an etcd snapshot is taken
{ pkgs, k3sPackage }:

let
  lib = pkgs.lib;
  token = pkgs.writeText "k3s-token" "rehearsal-token";
  pauseImage = pkgs.dockerTools.buildImage {
    name = "test.local/pause";
    tag = "local";
    copyToRoot = pkgs.buildEnv {
      name = "pause-env";
      paths = with pkgs; [ tini busybox ];
    };
    config.Entrypoint = [ "/bin/tini" "--" "/bin/sleep" "inf" ];
  };
  workload = pkgs.writeText "workload.yaml" ''
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: rehearsal
    spec:
      replicas: 2
      selector:
        matchLabels: { app: rehearsal }
      template:
        metadata:
          labels: { app: rehearsal }
        spec:
          tolerations: []
          containers:
            - name: pause
              image: test.local/pause:local
              imagePullPolicy: Never
  '';
  etcdctl = pkgs.writeShellScriptBin "etcdctl-k3s" ''
    d=/var/lib/rancher/k3s/server/tls/etcd
    exec ${pkgs.etcd}/bin/etcdctl --endpoints https://127.0.0.1:2379 \
      --cacert $d/server-ca.crt --cert $d/client.crt --key $d/client.key "$@"
  '';

  # One-way delay added to everything a VM sends, so each pair's round trip
  # is the sum of the two.
  delays = { fuji = 30; thinkcentre = 20; edge = 3; mixi = 20; };

  common = name: { config, ... }: {
    virtualisation = { memorySize = 2048; cores = 2; diskSize = 4096; };
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.kubectl pkgs.jq etcdctl ];
    environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    services.k3s = {
      enable = true;
      package = k3sPackage;
      tokenFile = token;
      images = [ pauseImage ];
      nodeIP = config.networking.primaryIPAddress;
      # Server-only flag; an agent refuses to start with it.
      disable = lib.mkIf (config.services.k3s.role == "server") [ "coredns" "local-storage" "metrics-server" "servicelb" "traefik" ];
      extraFlags = [ "--pause-image" "test.local/pause:local" ]
        ++ lib.optionals (config.services.k3s.role == "server") [
          "--flannel-backend=wireguard-native"
          "--flannel-iface" "eth1"
          "--egress-selector-mode=disabled"
        ]
        ++ lib.optionals (config.services.k3s.role == "agent") [ "--flannel-iface" "eth1" ];
    };
    systemd.services.wan-latency = {
      wantedBy = [ "multi-user.target" ];
      before = [ "k3s.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = "${pkgs.iproute2}/bin/tc qdisc replace dev eth1 root netem delay ${toString delays.${name}}ms";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "etcd-migration";

  nodes = {
    fuji = { ... }: {
      imports = [ (common "fuji") ];
      services.k3s.role = "server";
      # Step 2: the same server with --cluster-init, switched to at runtime
      # like a NixOS rebuild would.
      specialisation.etcd.configuration.services.k3s.clusterInit = true;
    };
    thinkcentre = { ... }: {
      imports = [ (common "thinkcentre") ];
      services.k3s = { role = "server"; serverAddr = "https://fuji:6443"; };
    };
    edge = { ... }: {
      imports = [ (common "edge") ];
      services.k3s = {
        role = "server";
        serverAddr = "https://fuji:6443";
        extraFlags = [
          "--disable-apiserver"
          "--disable-controller-manager"
          "--disable-scheduler"
          "--node-taint" "node-role.kubernetes.io/etcd=true:NoExecute"
        ];
      };
    };
    mixi = { ... }: {
      imports = [ (common "mixi") ];
      services.k3s = { role = "agent"; serverAddr = "https://fuji:6443"; };
    };
  };

  testScript = ''
    def members(node):
        out = node.succeed("etcdctl-k3s member list -w json")
        import json
        return sorted(m.get("name", "?") for m in json.loads(out)["members"])

    with subtest("1. fuji on SQLite, with a workload and data"):
        fuji.start()
        fuji.wait_for_unit("k3s")
        fuji.wait_until_succeeds("kubectl get node fuji | grep -w Ready", timeout=300)
        fuji.succeed("test -f /var/lib/rancher/k3s/server/db/state.db")
        fuji.succeed("kubectl create configmap rehearsal --from-literal=answer=42")
        fuji.succeed("kubectl apply -f ${workload}")
        fuji.wait_until_succeeds("kubectl rollout status deploy/rehearsal --timeout=10s", timeout=300)

    with subtest("2. fuji switched to etcd keeps its data"):
        fuji.succeed("/run/current-system/specialisation/etcd/bin/switch-to-configuration test")
        fuji.wait_until_succeeds("test -d /var/lib/rancher/k3s/server/db/etcd", timeout=300)
        fuji.wait_until_succeeds("kubectl get node fuji | grep -w Ready", timeout=300)
        assert fuji.succeed("kubectl get cm rehearsal -o jsonpath={.data.answer}").strip() == "42"
        fuji.wait_until_succeeds("kubectl rollout status deploy/rehearsal --timeout=10s", timeout=300)
        print("etcd members:", members(fuji))

    with subtest("3. thinkcentre joins as a server, edge etcd-only, mixi as agent"):
        thinkcentre.start()
        fuji.wait_until_succeeds("kubectl get node thinkcentre | grep -w Ready", timeout=600)
        edge.start()
        fuji.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 3 ]", timeout=600)
        print("etcd members:", members(fuji))
        mixi.start()
        fuji.wait_until_succeeds("kubectl get node mixi | grep -w Ready", timeout=600)
        taint = fuji.succeed("kubectl get node edge -o jsonpath='{.spec.taints[*].key}'")
        assert "node-role.kubernetes.io/etcd" in taint, taint
        on_edge = fuji.succeed("kubectl get pods -A -o wide --field-selector spec.nodeName=edge --no-headers | wc -l").strip()
        print("pods on edge:", on_edge)

    with subtest("4. fuji crashes, the other two keep the cluster"):
        fuji.crash()
        thinkcentre.wait_until_succeeds("kubectl get cm rehearsal", timeout=120)
        thinkcentre.succeed("kubectl create configmap written-without-fuji --from-literal=ok=yes")
        thinkcentre.wait_until_succeeds("kubectl get node fuji | grep -w NotReady", timeout=300)
        thinkcentre.succeed("kubectl get node mixi | grep -w Ready")
        print("health without fuji:", thinkcentre.succeed("etcdctl-k3s endpoint health --cluster 2>&1 || true"))

    with subtest("5. fuji comes back and rejoins"):
        fuji.start()
        thinkcentre.wait_until_succeeds("kubectl get node fuji | grep -w Ready", timeout=600)
        fuji.wait_until_succeeds("kubectl get cm written-without-fuji", timeout=300)
        fuji.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 3 ]", timeout=300)

    with subtest("6. etcd snapshot"):
        thinkcentre.succeed("k3s etcd-snapshot save --name rehearsal")
        thinkcentre.succeed("ls /var/lib/rancher/k3s/server/db/snapshots/ | grep rehearsal")
  '';
}
