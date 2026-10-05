# Rehearsal of the Nebula backbone for the servers (infrastructure #141,
# decision 2026-10-05): fuji, the thinkcentre, the edge, mixi and minima on
# their own overlay, with no control server to ask at boot.
#
#   nix build .#checks.x86_64-linux.nebula-backbone -L
#
# The network is modelled like the real one:
#   internet (VLAN 100): the edge, and the two sites' routers
#   RO (VLAN 1): fuji and minima behind NAT, UDP 4242 forwarded to fuji
#   DK (VLAN 2): the thinkcentre and mixi behind NAT, nothing forwarded
# Lighthouses and relays: the edge and fuji.
#
# Checks:
#   1. every server reaches every other over Nebula
#   2. the edge down: a restarted DK node still finds everyone through fuji
#   3. fuji down: everyone else still finds each other through the edge
#   4. cold start: everything off, everything on, full mesh again
{ pkgs }:

let
  lib = pkgs.lib;
  servers = { edge = 1; fuji = 2; thinkcentre = 3; mixi = 4; minima = 5; };
  meshIP = name: "10.99.0.${toString servers.${name}}";

  # Test-only certificates. The real CA stays offline.
  certs = pkgs.runCommand "nebula-test-certs" { nativeBuildInputs = [ pkgs.nebula ]; } ''
    mkdir $out && cd $out
    nebula-cert ca -name rehearsal -duration 8760h
    ${lib.concatStrings (lib.mapAttrsToList (name: _: ''
      nebula-cert sign -name ${name} -ip ${meshIP name}/24 -groups servers
    '') servers)}
  '';

  addr = node: iface: (lib.head node.networking.interfaces.${iface}.ipv4.addresses).address;

  # A server on the mesh. `public` is how the others reach the lighthouses.
  meshNode = name: { nodes, ... }: {
    services.nebula.networks.mesh = {
      enable = true;
      ca = "${certs}/ca.crt";
      cert = "${certs}/${name}.crt";
      key = "${certs}/${name}.key";
      isLighthouse = name == "edge" || name == "fuji";
      isRelay = name == "edge" || name == "fuji";
      # Lighthouses don't list lighthouses.
      lighthouses = lib.optionals (name != "edge" && name != "fuji") [ (meshIP "edge") (meshIP "fuji") ];
      relays = lib.optionals (name != "edge" && name != "fuji") [ (meshIP "edge") (meshIP "fuji") ];
      # Not 4242 except on the lighthouses (as in modules/nixos/nebula-mesh.nix): minima
      # on 4242 too took RO's public 4242 when its traffic was NATed, the port
      # forwarded to fuji, and the edge's packets for fuji went to minima.
      listen.port = if name == "edge" || name == "fuji" then 4242 else 4241;
      staticHostMap = {
        ${meshIP "edge"} = [ "${addr nodes.edge "eth1"}:4242" ];
        # fuji through RO's public address and the forwarded port, and on
        # the RO LAN directly (a router rarely loops its own forward back in).
        ${meshIP "fuji"} = [ "${addr nodes.rorouter "eth2"}:4242" "${addr nodes.fuji "eth1"}:4242" ];
      };
      settings.punchy = { punch = true; respond = true; };
      # As in the module: metrics only on the mesh address.
      settings.stats = { type = "prometheus"; listen = "${meshIP name}:8101"; path = "/metrics"; namespace = "nebula"; interval = "15s"; };
      firewall = {
        outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
        inbound = [ { port = "any"; proto = "any"; group = "servers"; } ];
      };
    };
    networking.firewall.trustedInterfaces = [ "nebula.mesh" ];
  };

  # A machine behind a site's NAT router.
  behind = router: { nodes, ... }: {
    virtualisation.vlans = [ (if router == "rorouter" then 1 else 2) ];
    networking.defaultGateway = addr nodes.${router} "eth1";
  };

  # A site's router: LAN on eth1, internet on eth2, NAT between them. Port
  # forwards only for traffic coming in from the internet side, like a real
  # router (NixOS's forwardPorts also catches the LAN's own outgoing packets
  # to that port).
  router = lanVlan: forward: { ... }: {
    virtualisation.vlans = [ lanVlan 100 ];
    networking.firewall.enable = false;
    networking.nat = {
      enable = true;
      internalInterfaces = [ "eth1" ];
      externalInterface = "eth2";
      extraCommands = lib.optionalString (forward != null)
        "iptables -w -t nat -A nixos-nat-pre -i eth2 -p udp --dport 4242 -j DNAT --to-destination ${forward}:4242";
    };
  };

  base = { ... }: {
    virtualisation.memorySize = 512;
    environment.systemPackages = [ pkgs.curl ];
  };
in
pkgs.testers.runNixOSTest {
  name = "nebula-backbone";

  nodes = {
    edge = { ... }: {
      imports = [ base (meshNode "edge") ];
      virtualisation.vlans = [ 100 ];
    };
    rorouter = { nodes, ... }: {
      imports = [ base (router 1 (addr nodes.fuji "eth1")) ];
    };
    dkrouter = { ... }: {
      imports = [ base (router 2 null) ];
    };
    fuji = { ... }: { imports = [ base (meshNode "fuji") (behind "rorouter") ]; };
    minima = { ... }: { imports = [ base (meshNode "minima") (behind "rorouter") ]; };
    thinkcentre = { ... }: { imports = [ base (meshNode "thinkcentre") (behind "dkrouter") ]; };
    mixi = { ... }: { imports = [ base (meshNode "mixi") (behind "dkrouter") ]; };
  };

  testScript = { nodes, ... }: ''
    import itertools
    servers = {
      ${lib.concatStringsSep ",\n  " (lib.mapAttrsToList (n: _: ''"${n}": "${meshIP n}"'') servers)}
    }
    machines_by_name = {"edge": edge, "fuji": fuji, "thinkcentre": thinkcentre, "mixi": mixi, "minima": minima}

    def full_mesh(names, timeout=120):
        for a, b in itertools.permutations(names, 2):
            machines_by_name[a].wait_until_succeeds(f"ping -c 1 -W 2 {servers[b]}", timeout=timeout)
        print("mesh ok:", sorted(names))

    def start_sites():
        # Routers first, with their NAT loaded, like real ones. A flow that
        # starts before the rules keeps going un-NATed.
        for r in (rorouter, dkrouter):
            r.start()
        for r in (rorouter, dkrouter):
            r.wait_for_unit("nat.service")
        start_all()

    def no_direct_path_into_dk():
        # The model: nobody outside DK can open a connection into it.
        edge.fail("ping -c 1 -W 2 ${addr nodes.thinkcentre "eth1"}")

    with subtest("1. every server reaches every other"):
        start_sites()
        for m in machines_by_name.values():
            m.wait_for_unit("nebula@mesh.service")
        no_direct_path_into_dk()
        full_mesh(servers.keys())
        # The two DK hosts talk over their LAN, not through a relay.
        direct = any(
            m.execute("journalctl -u nebula@mesh -o cat | grep -qE 'certName=(thinkcentre|mixi) .*from=.192[.]168[.]2[.][0-9]+:4241'")[0] == 0
            for m in (thinkcentre, mixi))
        assert direct, "thinkcentre and mixi aren't talking over their LAN"
        # Metrics answer on the mesh address only (Prometheus scrapes them there).
        for n, ip in servers.items():
            fuji.succeed(f"curl -sf -m 5 -o /tmp/m http://{ip}:8101/metrics && grep -q ^nebula_ /tmp/m")
        minima.fail("curl -sf -m 5 http://${addr nodes.fuji "eth1"}:8101/metrics")

    with subtest("2. edge down: a restarted DK node finds everyone through fuji"):
        edge.crash()
        thinkcentre.succeed("systemctl restart nebula@mesh.service")
        mixi.succeed("systemctl restart nebula@mesh.service")
        full_mesh(["fuji", "thinkcentre", "mixi", "minima"], timeout=180)
        edge.start()
        edge.wait_for_unit("nebula@mesh.service")
        full_mesh(servers.keys(), timeout=180)

    with subtest("3. fuji down: the rest find each other through the edge"):
        fuji.crash()
        thinkcentre.succeed("systemctl restart nebula@mesh.service")
        minima.succeed("systemctl restart nebula@mesh.service")
        full_mesh(["edge", "thinkcentre", "mixi", "minima"], timeout=180)
        fuji.start()
        fuji.wait_for_unit("nebula@mesh.service")
        full_mesh(servers.keys(), timeout=180)

    with subtest("4. cold start: everything off, everything on"):
        for m in machines:
            m.shutdown()
        start_sites()
        for m in machines_by_name.values():
            m.wait_for_unit("nebula@mesh.service")
        full_mesh(servers.keys(), timeout=240)
  '';
}
