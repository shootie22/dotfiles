# Rehearsal of failing over a service with files (infrastructure, decision
# 2026-10-06 "Services with files fail over by themselves"), on the cluster as
# it is since Phase 3: etcd on fuji, the thinkcentre and the edge over Nebula,
# RO and DK behind NAT.
#
#   nix build .#checks.x86_64-linux.site-failover -L
#
# The service is a counter that writes to its folder every second, so a copy
# that's behind, or two copies running at once, both show.
#   1. cluster up, the thinkcentre takes the label (that's where the data is)
#   2. the service runs there, its folder gets copied to fuji
#   3. the thinkcentre crashes: fuji takes over on the copy
#   4. the thinkcentre comes back as the standby and gets fuji's copies
#   5. fuji gets cut off: it stops the service itself, and the thinkcentre
#      (with the edge, so etcd's majority) takes over; never both at once
#   6. the cut heals: fuji is the standby, nothing ran twice
# Times are printed.
{ pkgs, k3sPackage }:

let
  lib = pkgs.lib;
  token = pkgs.writeText "k3s-token" "rehearsal-token";

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

  # Stand-in for sops-nix: the copy key is made at run time.
  sopsStub = {
    options.sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        freeformType = lib.types.attrs;
        options.path = lib.mkOption { type = lib.types.str; default = "/etc/standby-copy-key"; };
      });
      default = { };
    };
  };

  k3sNode = name: { config, nodes, ... }: {
    imports = [ (nebulaNode name) ];
    virtualisation = { memorySize = 3072; cores = 2; diskSize = 8192; };
    virtualisation.vlans = [ siteVlan.${name} ];
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.kubectl pkgs.jq pkgs.iptables pkgs.curl etcdctl ];
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
      images = [ k3sPackage."airgap-images-amd64-tar-zst" ];
      extraFlags = serverFlags name ++ [ "--node-label=topology.kubernetes.io/zone=${zone.${name}}" ]
        ++ lib.optionals (name == "edge") [
          "--disable-apiserver" "--disable-controller-manager" "--disable-scheduler"
          "--node-taint=node-role.kubernetes.io/etcd=true:NoExecute"
        ];
    };
    systemd.services.k3s = { after = [ "nebula@mesh.service" ]; wants = [ "nebula@mesh.service" ]; };
  };

  # fuji and the thinkcentre: the pair the service moves between.
  pairNode = name: peer: data: {
    imports = [ (k3sNode name) ../modules/nixos/standby-copy.nix ../modules/nixos/site-failover sopsStub ];
    services.openssh = {
      enable = true;
      authorizedKeysInHomedir = false;
      settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };
    };
    dotfiles.standbyCopy = {
      publicKeys = { fuji = "ssh-ed25519 PLACEHOLDER"; thinkcentre = "ssh-ed25519 PLACEHOLDER"; };
      receive = { enable = true; dir = if name == "fuji" then "/srv/standby" else "/srv/receive"; from = [ peer ]; };
      # Every 20 seconds here instead of 10 minutes.
      send.minecraft-hc.interval = lib.mkForce "*:*:0/20";
    };
    dotfiles.siteFailover.services.minecraft-hc = { inherit data peer; initial = name == "thinkcentre"; };
    systemd.tmpfiles.rules = lib.optional (name == "thinkcentre") "d /srv/live/app 0755 root root -";
  };
in
pkgs.testers.runNixOSTest {
  name = "site-failover";

  nodes = {
    rorouter = { nodes, ... }: { imports = [ (router 1 (addr nodes.fuji "eth1")) ]; };
    dkrouter = { ... }: { imports = [ (router 2 null) ]; };
    fuji = pairNode "fuji" "thinkcentre" "/srv/standby/thinkcentre/minecraft-hc";
    # A pattern, like a local-path volume's folder.
    thinkcentre = pairNode "thinkcentre" "fuji" "/srv/li*/app";
    # The game relay follows the label (modules/nixos/game-relay.nix).
    edge = { imports = [ (k3sNode "edge") ../modules/nixos/game-relay.nix ]; dotfiles.gameRelay.enable = true; };
  };

  testScript = ''
    import textwrap
    import time

    def api(timeout=600):
        end = time.time() + timeout
        while time.time() < end:
            for m in (fuji, thinkcentre):
                if m.execute("kubectl get --raw /readyz >/dev/null 2>&1")[0] == 0:
                    return m
            time.sleep(3)
        raise Exception("no API")

    def relay_points_at(ip, timeout=120):
        edge.wait_until_succeeds(
            f"systemctl start game-relay-targets && grep -qx '  6767 {ip};' /run/game-relay/targets.conf "
            f"&& grep -qx '  51751 {ip};' /run/game-relay/targets.conf && systemctl is-active -q nginx",
            timeout=timeout)

    def holder(via):
        return via.succeed("kubectl get nodes -l ha.radunenu.com/minecraft-hc=active -o jsonpath='{.items[*].metadata.name}'").strip()

    def running_on(m):
        # The counter's container on this machine, read from the runtime's
        # files: containerd may be down on a node that's cut off.
        return m.execute(
            "for d in /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/*/; do "
            "jq -e '.mounts[] | select(.source == \"/srv/ha/minecraft-hc\")' $d/config.json >/dev/null 2>&1 && "
            "kill -0 $(cat $d/init.pid) 2>/dev/null && exit 0; done; exit 1"
        )[0] == 0

    def trust(m):
        # m accepts its peer's run-time key (redone after a reboot: NixOS
        # rewrites authorized_keys.d at boot).
        peer = thinkcentre if m is fuji else fuji
        pub = peer.succeed("cut -d' ' -f1,2 /etc/standby-copy-key.pub").strip()
        m.succeed(
            "f=/etc/ssh/authorized_keys.d/standby; line=$(cat $f); rm $f; "
            f"echo \"''${{line%ssh-ed25519 PLACEHOLDER}}{pub}\" > $f; chmod 0444 $f"
        )

    FUJI = "/srv/standby/thinkcentre/minecraft-hc"  # the service's folder on fuji

    def count(m, path):
        return int(m.succeed(f"cat {path}/n").strip() or 0)

    app = """
    apiVersion: apps/v1
    kind: Deployment
    metadata: {name: app}
    spec:
      replicas: 1
      strategy: {type: Recreate}
      selector: {matchLabels: {app: app}}
      template:
        metadata: {labels: {app: app}}
        spec:
          nodeSelector: {ha.radunenu.com/minecraft-hc: active}
          tolerations:
            - {key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30}
            - {key: node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: 30}
          containers:
            - name: app
              image: IMAGE
              imagePullPolicy: Never
              command: [sh, -c, 'n=$(cat /data/n 2>/dev/null || echo 0); while true; do n=$((n+1)); echo $n > /data/n; echo "$NODE $n" >> /data/log; sleep 1; done']
              env: [{name: NODE, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}]
              volumeMounts: [{name: data, mountPath: /data}]
          volumes: [{name: data, hostPath: {path: /srv/ha/minecraft-hc, type: Directory}}]
    """

    with subtest("1. cluster up, the thinkcentre takes the label"):
        for r in (rorouter, dkrouter):
            r.start()
        for r in (rorouter, dkrouter):
            r.wait_for_unit("nat.service")
        for m in (fuji, thinkcentre, edge):
            m.start()
        fuji.wait_until_succeeds("[ $(etcdctl-k3s member list | grep -c started) -eq 3 ]", timeout=900)
        api().wait_until_succeeds("kubectl get node thinkcentre | grep -w Ready", timeout=600)
        # Copy keys, made here; each side trusts the other's.
        for m in (fuji, thinkcentre):
            m.succeed("ssh-keygen -q -t ed25519 -N ''' -f /etc/standby-copy-key && chmod 0400 /etc/standby-copy-key")
        for m in (fuji, thinkcentre):
            trust(m)
        a = api()
        a.wait_until_succeeds("kubectl get nodes -l ha.radunenu.com/minecraft-hc=active -o name | grep -x node/thinkcentre", timeout=300)
        assert holder(a) == "thinkcentre", holder(a)

    with subtest("2. the service runs on the thinkcentre and gets copied to fuji"):
        a = api()
        image = thinkcentre.succeed("k3s crictl images -o json | jq -r '.images[].repoTags[]' | grep busybox | head -1").strip()
        a.succeed(f"cat > /tmp/app.yaml <<'YAML'\n{textwrap.dedent(app).replace('IMAGE', image)}\nYAML")
        a.succeed("kubectl apply -f /tmp/app.yaml")
        thinkcentre.wait_until_succeeds("test \"$(cat /srv/live/app/n)\" -gt 5", timeout=300)
        fuji.wait_until_succeeds("test -e /srv/standby/thinkcentre/minecraft-hc/.standby-copy-ok", timeout=300)
        # The standby has the copy, but no /srv/ha/minecraft-hc: nothing could run on it.
        fuji.fail("test -e /srv/ha/minecraft-hc")
        thinkcentre.succeed("mountpoint -q /srv/ha/minecraft-hc")
        print("copied to fuji:", count(fuji, FUJI), "live:", count(thinkcentre, "/srv/live/app"))
        relay_points_at("10.99.0.3")
        # fuji isn't active, so it doesn't send.
        fuji.succeed("systemctl start standby-copy-minecraft-hc.service")
        fuji.succeed("journalctl -u standby-copy-minecraft-hc | grep -q 'not the active node'")
        assert not running_on(fuji)

    with subtest("3. the thinkcentre crashes: fuji takes over on the copy"):
        thinkcentre.succeed("systemctl start standby-copy-minecraft-hc.service")
        copied = count(fuji, FUJI)
        t0 = time.time()
        # A real server unpacked its images long ago; this one minutes ago, and
        # a crash before they reach the disk leaves containerd broken.
        thinkcentre.succeed("sync")
        thinkcentre.crash()
        fuji.wait_until_succeeds("kubectl get nodes -l ha.radunenu.com/minecraft-hc=active -o name | grep -x node/fuji", timeout=600)
        print(f"TIME crash: fuji has the label after ~{time.time() - t0:.0f} s")
        fuji.wait_until_succeeds(f"test \"$(cat /srv/ha/minecraft-hc/n)\" -gt {copied + 3}", timeout=600)
        print(f"TIME crash: the service runs on fuji after ~{time.time() - t0:.0f} s, carrying on from {copied}")
        relay_points_at("10.99.0.2")
        print(f"TIME crash: the game relay points at fuji after ~{time.time() - t0:.0f} s")

    with subtest("4. the thinkcentre comes back as the standby"):
        thinkcentre.start()
        thinkcentre.wait_for_unit("sshd.service")
        trust(thinkcentre)
        fuji.wait_until_succeeds("kubectl get node thinkcentre | grep -w Ready", timeout=600)
        time.sleep(30)
        assert holder(fuji) == "fuji", holder(fuji)
        assert not running_on(thinkcentre)
        thinkcentre.fail("test -e /srv/ha/minecraft-hc")
        thinkcentre.succeed("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9112/minecraft-hc | grep -x 503")
        thinkcentre.succeed("curl -s http://127.0.0.1:9112/minecraft-hc | grep -q 'holder=fuji$'")
        # fuji's copies now land in the thinkcentre's folder.
        fuji.succeed("systemctl start standby-copy-minecraft-hc.service")
        n = count(fuji, "/srv/ha/minecraft-hc")
        thinkcentre.succeed(f"test \"$(cat /srv/live/app/n)\" -ge {n - 2}")
        print("the thinkcentre has fuji's copy:", count(thinkcentre, "/srv/live/app"))

    with subtest("5. fuji gets cut off: it stops, the thinkcentre takes over, never both"):
        t0 = time.time()
        fuji.succeed("iptables -I INPUT -i nebula.mesh -j DROP; iptables -I OUTPUT -o nebula.mesh -j DROP")
        stopped = started = None
        while time.time() - t0 < 600 and (stopped is None or started is None):
            on_fuji, on_tc = running_on(fuji), running_on(thinkcentre)
            assert not (on_fuji and on_tc), "running in both sites at once"
            if stopped is None and not on_fuji:
                stopped = time.time() - t0
            if started is None and on_tc:
                started = time.time() - t0
            time.sleep(1)
        assert stopped is not None and started is not None, (stopped, started)
        print(f"TIME cut: fuji stopped the service after ~{stopped:.0f} s, the thinkcentre runs it after ~{started:.0f} s")
        assert stopped < started
        relay_points_at("10.99.0.3")
        # fuji can't send while cut off (it can't ask the cluster).
        fuji.fail("systemctl start standby-copy-minecraft-hc.service")

    with subtest("6. the cut heals: fuji is the standby"):
        fuji.succeed("iptables -D INPUT -i nebula.mesh -j DROP; iptables -D OUTPUT -o nebula.mesh -j DROP")
        thinkcentre.wait_until_succeeds("kubectl get node fuji | grep -w Ready", timeout=600)
        time.sleep(30)
        assert holder(thinkcentre) == "thinkcentre"
        assert not running_on(fuji)
        thinkcentre.succeed("systemctl start standby-copy-minecraft-hc.service")
        n = count(thinkcentre, "/srv/live/app")
        fuji.succeed(f"test \"$(cat {FUJI}/n)\" -ge {n - 2}")
        fuji.fail("test -e /srv/ha/minecraft-hc")
        # Who wrote, in order: the copy's lost minutes show as a step back
        # in the count at each takeover.
        lines = thinkcentre.succeed("cat /srv/live/app/log").splitlines()
        runs = []
        for l in lines:
            node = l.split()[0]
            if not runs or runs[-1][0] != node:
                runs.append([node, l.split()[1], l.split()[1]])
            runs[-1][2] = l.split()[1]
        print("writers in order:", runs)
  '';
}
