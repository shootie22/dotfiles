# Rehearsal of Phase 3 on the Nebula backbone (infrastructure #20-#26, #141):
# the cluster moves from SQLite on fuji to etcd across fuji, the thinkcentre
# and the edge, and from the tailnet to Nebula, then has to survive without
# the tailnet at all: the case that blocked the first plan (#37).
#
#   nix build .#checks.x86_64-linux.etcd-over-nebula -L
#
# Network, like the real one: RO and DK behind NAT routers, the edge on the
# internet, Nebula lighthouses on the edge and fuji (UDP forwarded in RO).
# The tailnet is a flat extra network (VLAN 10) that can be switched off.
#
# Steps:
#   1. today: fuji a server on SQLite, the thinkcentre and mixi agents, all on
#      the tailnet; pods on all three reach each other
#   2. fuji to etcd and onto its Nebula address in one switch: data kept
#   3. the thinkcentre becomes the second server, the edge the etcd-only third
#      member, mixi moves to Nebula; every etcd member on a Nebula address
#   4. the tailnet goes away: the cluster and the pod network keep working
#   5. fuji crashes and comes back with no tailnet: it rejoins by itself
#   6. cold start of everything with no tailnet: the cluster comes back
# Pods reach each other across nodes at every step, with big packets too:
# flannel's WireGuard runs inside Nebula, and a wrong MTU only shows there.
{ pkgs, k3sPackage }:

let
  lib = pkgs.lib;
  token = pkgs.writeText "k3s-token" "rehearsal-token";

  # Nebula --------------------------------------------------------------------
  mesh = { edge = 1; fuji = 2; thinkcentre = 3; mixi = 4; };
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
      settings = {
        punchy = { punch = true; respond = true; };
        # As in modules/nixos/nebula-mesh.nix: never over the tailnet.
        lighthouse.local_allow_list.interfaces = { "eth2" = false; "flannel.*" = false; "cni.*" = false; "veth.*" = false; };
        lighthouse.remote_allow_list = { "0.0.0.0/0" = true; "192.168.10.0/24" = false; "10.42.0.0/16" = false; };
      };
      firewall = {
        outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
        inbound = [ { port = "any"; proto = "any"; group = "servers"; } ];
      };
    };
  };

  # Sites -------------------------------------------------------------------
  # eth1: the site's LAN (or the internet for the edge). eth2: the tailnet.
  siteVlan = { edge = 100; fuji = 1; thinkcentre = 2; mixi = 2; };
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

  # k3s -----------------------------------------------------------------------
  pauseImage = pkgs.dockerTools.buildImage {
    name = "test.local/pause";
    tag = "local";
    copyToRoot = pkgs.buildEnv { name = "pause-env"; paths = with pkgs; [ tini busybox ]; };
    config.Entrypoint = [ "/bin/tini" "--" "/bin/sleep" "inf" ];
  };
  probes = pkgs.writeText "probes.yaml" ''
    apiVersion: apps/v1
    kind: DaemonSet
    metadata: { name: probe }
    spec:
      selector: { matchLabels: { app: probe } }
      template:
        metadata: { labels: { app: probe } }
        spec:
          containers:
            - name: probe
              image: test.local/pause:local
              imagePullPolicy: Never
              securityContext: { capabilities: { add: [ NET_RAW ] } }
  '';
  etcdctl = pkgs.writeShellScriptBin "etcdctl-k3s" ''
    d=/var/lib/rancher/k3s/server/tls/etcd
    exec ${pkgs.etcd}/bin/etcdctl --endpoints https://127.0.0.1:2379 \
      --cacert $d/server-ca.crt --cert $d/client.crt --key $d/client.key "$@"
  '';

  # Today's flags (hosts/*/configuration.nix): the node address is the LAN
  # one (on the real fuji and minima a public IPv6 one), not reachable from
  # the other site; flannel uses the tailnet address (--flannel-external-ip).
  # The API is advertised where every node reaches it (the real one is fuji's
  # LAN address, routed to DK over the tailnet).
  disabled = [ "--disable" "coredns" "--disable" "local-storage" "--disable" "metrics-server" "--disable" "servicelb" "--disable" "traefik" ];
  todayServer = lanIP: tailIP: [
    "server" "--node-ip" lanIP "--node-external-ip" tailIP "--advertise-address" tailIP
    "--egress-selector-mode=disabled" "--flannel-backend=wireguard-native" "--flannel-external-ip"
  ] ++ disabled;
  todayAgent = server: lanIP: tailIP: [ "agent" "--server" "https://${server}:6443" "--node-ip" lanIP "--node-external-ip" tailIP ];
  # On Nebula: the node's mesh address for everything, and flannel on the
  # mesh interface, so its WireGuard takes its MTU from Nebula's. The servers
  # keep --flannel-external-ip: while an agent isn't moved yet, flannel has
  # to keep using its tailnet address, not its LAN one the other site can't
  # reach.
  meshServer = ip: [
    "server" "--node-ip" ip "--node-external-ip" ip "--advertise-address" ip
    "--egress-selector-mode=disabled" "--flannel-backend=wireguard-native" "--flannel-iface" "nebula.mesh" "--flannel-external-ip"
  ] ++ disabled;
  meshAgent = ip: [ "agent" "--server" "https://${meshIP "fuji"}:6443" "--node-ip" ip "--node-external-ip" ip "--flannel-iface" "nebula.mesh" ];

  # Which k3s a node runs is read at start from /var/lib/sim/mode, which
  # survives reboots like a deployed config does (a test VM always boots its
  # base configuration, so a switch at runtime wouldn't).
  k3sNode = name: modes: { config, ... }: {
    virtualisation = { memorySize = 2048; cores = 2; diskSize = 4096; };
    virtualisation.vlans = [ siteVlan.${name} 10 ];
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.kubectl pkgs.jq pkgs.wireguard-tools etcdctl ];
    environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    services.k3s = {
      enable = true;
      package = k3sPackage;
      images = [ pauseImage ];
    };
    systemd.services.k3s = {
      # As in modules/nixos/k3s-tailnet-guard.nix, but for the mesh.
      after = [ "nebula@mesh.service" "tailnet-sim.service" ];
      wants = [ "nebula@mesh.service" ];
      unitConfig.ConditionPathExists = "/var/lib/sim/mode";
      serviceConfig.ExecStart = lib.mkForce (pkgs.writeShellScript "k3s-sim" ''
        mode=$(cat /var/lib/sim/mode)
        case "$mode" in
        ${lib.concatStrings (lib.mapAttrsToList (m: args: ''
          ${m}) exec ${k3sPackage}/bin/k3s ${lib.escapeShellArgs (args ++ [ "--token-file" "${token}" "--pause-image" "test.local/pause:local" ])} ;;
        '') modes)}
          *) echo "unknown mode $mode"; exit 1 ;;
        esac
      '');
    };
    # The tailnet can be "down" across reboots: Headscale gone.
    systemd.services.tailnet-sim = {
      wantedBy = [ "multi-user.target" ];
      before = [ "k3s.service" "nebula@mesh.service" ];
      after = [ "network.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = "if [ -e /var/lib/tailnet-down ]; then ${pkgs.iproute2}/bin/ip link set eth2 down; fi";
    };
  };

  site = router: { nodes, ... }: {
    networking.defaultGateway = addr nodes.${router} "eth1";
  };
in
pkgs.testers.runNixOSTest {
  name = "etcd-over-nebula";

  nodes = {
    rorouter = { nodes, ... }: { imports = [ (router 1 (addr nodes.fuji "eth1")) ]; };
    dkrouter = { ... }: { imports = [ (router 2 null) ]; };

    fuji = { config, nodes, ... }: {
      imports = [
        (k3sNode "fuji" {
          today = todayServer (addr nodes.fuji "eth1") (addr nodes.fuji "eth2");
          etcd = meshServer (meshIP "fuji") ++ [ "--cluster-init" ];
        })
        (nebulaNode "fuji") (site "rorouter")
      ];
    };
    thinkcentre = { config, nodes, ... }: {
      imports = [
        (k3sNode "thinkcentre" {
          today = todayAgent (addr nodes.fuji "eth2") (addr nodes.thinkcentre "eth1") (addr nodes.thinkcentre "eth2");
          server = meshServer (meshIP "thinkcentre") ++ [ "--server" "https://${meshIP "fuji"}:6443" ];
        })
        (nebulaNode "thinkcentre") (site "dkrouter")
      ];
    };
    mixi = { config, nodes, ... }: {
      imports = [
        (k3sNode "mixi" {
          today = todayAgent (addr nodes.fuji "eth2") (addr nodes.mixi "eth1") (addr nodes.mixi "eth2");
          mesh = meshAgent (meshIP "mixi");
        })
        (nebulaNode "mixi") (site "dkrouter")
      ];
    };
    # Not in the cluster today; joins as the etcd-only member in step 3.
    edge = { config, ... }: {
      imports = [
        (k3sNode "edge" {
          etcd = meshServer (meshIP "edge") ++ [
            "--server" "https://${meshIP "fuji"}:6443"
            "--disable-apiserver" "--disable-controller-manager" "--disable-scheduler"
            "--node-taint" "node-role.kubernetes.io/etcd=true:NoExecute"
          ];
        })
        (nebulaNode "edge")
      ];
    };
  };

  testScript = { nodes, ... }: ''
    import json, itertools
    MESH = {"edge": "${meshIP "edge"}", "fuji": "${meshIP "fuji"}", "thinkcentre": "${meshIP "thinkcentre"}", "mixi": "${meshIP "mixi"}"}
    k3s_nodes = [fuji, thinkcentre, mixi]

    def api(timeout=600):
        # Whichever server answers, waiting for one to.
        import time
        end = time.time() + timeout
        while time.time() < end:
            for m in (fuji, thinkcentre):
                if m.execute("kubectl get --raw /readyz >/dev/null 2>&1")[0] == 0:
                    return m
            time.sleep(5)
        raise Exception("no API")

    def members(node):
        out = json.loads(node.succeed("etcdctl-k3s member list -w json"))["members"]
        return sorted((m.get("name", "?"), m.get("peerURLs", [])) for m in out)

    def dump_network():
        for x in k3s_nodes + [edge]:
            print(x.name, x.execute("wg show flannel-wg 2>&1; ip -4 -br addr show flannel-wg; ip route | grep 10.42")[1])
        print(api().execute("kubectl get pods -l app=probe -o wide; kubectl get nodes -o wide")[1])

    def pods_reach_each_other(nodes_expected, timeout=300):
        try:
            _pods_reach_each_other(nodes_expected, timeout)
        except Exception:
            dump_network()
            raise

    def _pods_reach_each_other(nodes_expected, timeout=300):
        a = api()
        # Ready, not just Running: after a node reboots, its pod's old status
        # (and old IP) lingers until the kubelet has restarted the container.
        a.wait_until_succeeds(
            f"[ $(kubectl get pods -l app=probe -o json | jq '[.items[] | select(.status.containerStatuses[0].ready == true and .status.containerStatuses[0].state.running != null)] | length') -ge {nodes_expected} ]",
            timeout=timeout)
        a.wait_until_succeeds("kubectl rollout status ds/probe --timeout=10s", timeout=timeout)
        pods = json.loads(a.succeed("kubectl get pods -l app=probe -o json"))["items"]
        pods = [(p["metadata"]["name"], p["spec"]["nodeName"], p["status"]["podIP"]) for p in pods if p["status"].get("podIP")]
        for (pa, na, _), (pb, nb, ipb) in itertools.permutations(pods, 2):
            # Small, then big enough to need the full MTU path.
            # The target's address is read on every try: after a reboot it changes.
            ip = f"$(kubectl get pod {pb} -o jsonpath={{.status.podIP}})"
            a.wait_until_succeeds(f"kubectl exec {pa} -- ping -c 1 -W 2 {ip}", timeout=240)
            a.wait_until_succeeds(f"kubectl exec {pa} -- ping -c 1 -W 2 -s 1150 {ip}", timeout=60)
        print("pods reach each other:", sorted((n, ip) for _, n, ip in pods))

    def set_mode(m, mode):
        m.succeed(f"mkdir -p /var/lib/sim && echo {mode} > /var/lib/sim/mode && systemctl restart k3s")

    def start_sites():
        for r in (rorouter, dkrouter):
            r.start()
        for r in (rorouter, dkrouter):
            r.wait_for_unit("nat.service")

    with subtest("1. today: SQLite on fuji, agents on the tailnet"):
        start_sites()
        for m in k3s_nodes + [edge]:
            m.start()
        set_mode(fuji, "today")
        fuji.wait_until_succeeds("kubectl get node fuji | grep -w Ready", timeout=300)
        set_mode(thinkcentre, "today")
        set_mode(mixi, "today")
        fuji.succeed("kubectl create configmap rehearsal --from-literal=answer=42")
        fuji.succeed("kubectl apply -f ${probes}")
        for n in ("thinkcentre", "mixi"):
            fuji.wait_until_succeeds(f"kubectl get node {n} | grep -w Ready", timeout=300)
        pods_reach_each_other(3)

    with subtest("2. fuji to etcd and onto Nebula"):
        set_mode(fuji, "etcd")
        fuji.wait_until_succeeds("test -d /var/lib/rancher/k3s/server/db/etcd", timeout=300)
        fuji.wait_until_succeeds(f"kubectl get node fuji -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}' | grep -x {MESH['fuji']}", timeout=300)
        assert fuji.succeed("kubectl get cm rehearsal -o jsonpath={.data.answer}").strip() == "42"
        pods_reach_each_other(3)

    with subtest("3. thinkcentre and edge join etcd, mixi moves to Nebula"):
        set_mode(thinkcentre, "server")
        fuji.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 2 ]", timeout=600)
        set_mode(edge, "etcd")
        fuji.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 3 ]", timeout=600)
        set_mode(mixi, "mesh")
        fuji.wait_until_succeeds(f"kubectl get node mixi -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}' | grep -x {MESH['mixi']}", timeout=300)
        m = members(fuji)
        print("etcd members:", m)
        assert all(all(u.startswith("https://10.99.0.") for u in urls) for _, urls in m), m
        # The migration copies the API's lease for fuji's old address without
        # its expiry, so the kubernetes Service would keep that address as an
        # endpoint forever (found on the real cluster, 5 Oct). The runbook's fix:
        # delete leases that aren't a live server's.
        leases = fuji.succeed("etcdctl-k3s get /registry/masterleases/ --prefix --keys-only").split()
        print("API leases:", leases)
        for k in leases:
            if not k.startswith("/registry/masterleases/10.99.0."):
                fuji.succeed(f"etcdctl-k3s del {k}")
        fuji.wait_until_succeeds(
            "[ \"$(kubectl get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[*].endpoints[*].addresses[*]}' | tr ' ' '\\n' | sort | tr '\\n' ' ')\" = "
            f"\"{MESH['fuji']} {MESH['thinkcentre']} \" ]", timeout=60)
        pods_reach_each_other(3)

    with subtest("4. the tailnet goes away"):
        for x in k3s_nodes + [edge]:
            x.succeed("touch /var/lib/tailnet-down; ip link set eth2 down")
        thinkcentre.wait_until_succeeds("kubectl create configmap without-tailnet --from-literal=ok=yes", timeout=120)
        pods_reach_each_other(3)

    with subtest("5. fuji crashes and comes back without the tailnet"):
        fuji.crash()
        thinkcentre.wait_until_succeeds("kubectl create configmap while-fuji-down --from-literal=ok=yes", timeout=180)
        fuji.start()
        fuji.wait_until_succeeds("kubectl get cm while-fuji-down", timeout=600)
        fuji.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 3 ]", timeout=600)
        fuji.wait_until_succeeds("kubectl get node fuji | grep -w Ready", timeout=600)
        pods_reach_each_other(3)

    with subtest("6. cold start of everything, no tailnet"):
        for x in k3s_nodes + [edge]:
            x.shutdown()
        for r in (rorouter, dkrouter):
            r.shutdown()
        start_sites()
        for x in k3s_nodes + [edge]:
            x.start()
        for x in (fuji, thinkcentre):
            x.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 3 ]", timeout=900)
        api().wait_until_succeeds("kubectl get cm without-tailnet", timeout=300)
        for n in ("fuji", "thinkcentre", "mixi"):
            api().wait_until_succeeds(f"kubectl get node {n} | grep -w Ready", timeout=600)
        pods_reach_each_other(3)
  '';
}
