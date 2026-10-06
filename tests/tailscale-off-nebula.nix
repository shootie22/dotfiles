# Tailscale offers its peers every address a host has, Nebula's included, and
# picked the path through Nebula between fuji and the thinkcentre (6 Oct).
# The tailnet would then quietly run over the mesh. Tailscale marks its own
# packets (fwmark 0x80000), so a routing rule refuses those towards the mesh,
# like modules/nixos/k3s-tailnet-guard.nix does for the pod network.
#
#   nix build .#checks.x86_64-linux.tailscale-off-nebula -L
#
# b drops tailscale's port on its LAN, so the only direct path left between a
# and b is through Nebula. Without the rule, tailscale should take it; with
# the rule, it mustn't (it falls back to the relay), and the tailnet still
# works.
{ pkgs }:
let
  lib = pkgs.lib;
  tls = pkgs.runCommand "selfSignedCerts" { buildInputs = [ pkgs.openssl ]; } ''
    openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
      -days 365 -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    mkdir -p $out; cp key.pem cert.pem $out
  '';
  certs = pkgs.runCommand "nebula-test-certs" { nativeBuildInputs = [ pkgs.nebula ]; } ''
    mkdir $out && cd $out
    nebula-cert ca -name test -duration 8760h
    nebula-cert sign -name a -ip 10.99.0.1/24 -groups servers
    nebula-cert sign -name b -ip 10.99.0.2/24 -groups servers
  '';
  addr = node: (lib.head node.networking.interfaces.eth1.ipv4.addresses).address;
  rule = "priority 5201 fwmark 0x80000/0xff0000 to 10.99.0.0/24 unreachable";
  node = name: { nodes, ... }: {
    networking.firewall.enable = false;
    security.pki.certificateFiles = [ "${tls}/cert.pem" ];
    environment.systemPackages = [ pkgs.iptables ];
    services.tailscale.enable = true;
    services.nebula.networks.mesh = {
      enable = true;
      ca = "${certs}/ca.crt";
      cert = "${certs}/${name}.crt";
      key = "${certs}/${name}.key";
      isLighthouse = name == "a";
      lighthouses = lib.optional (name != "a") "10.99.0.1";
      listen.port = 4242;
      staticHostMap."10.99.0.1" = [ "${addr nodes.a}:4242" ];
      firewall = {
        outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
        inbound = [ { port = "any"; proto = "any"; host = "any"; } ];
      };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "tailscale-off-nebula";
  nodes = {
    headscale = { ... }: {
      networking.firewall.enable = false;
      services.headscale = {
        enable = true;
        port = 8080;
        settings = {
          server_url = "https://headscale";
          ip_prefixes = [ "100.64.0.0/10" ];
          derp.server = { enabled = true; region_id = 999; stun_listen_addr = "0.0.0.0:3478"; };
          derp.urls = [ ];
          dns = { magic_dns = false; override_local_dns = false; };
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts.headscale = {
          addSSL = true;
          sslCertificate = "${tls}/cert.pem";
          sslCertificateKey = "${tls}/key.pem";
          locations."/" = { proxyPass = "http://127.0.0.1:8080"; proxyWebsockets = true; };
        };
      };
      environment.systemPackages = [ pkgs.headscale ];
    };
    a = node "a";
    b = node "b";
  };
  testScript = ''
    start_all()
    headscale.wait_for_unit("headscale")
    headscale.wait_for_open_port(443)
    headscale.succeed("headscale users create test")
    uid = headscale.succeed("headscale users list -o json | ${pkgs.jq}/bin/jq -r '.[0].id'").strip()
    key = headscale.succeed(f"headscale preauthkeys -u {uid} create --reusable").strip().split()[-1]
    for m in (a, b):
        m.wait_for_unit("nebula@mesh.service")
        m.wait_for_unit("tailscaled")
        m.succeed(f"tailscale up --login-server https://headscale --auth-key {key}")
    a.wait_until_succeeds("ping -c 1 -W 2 10.99.0.2", timeout=60)

    # Only the Nebula path left for a direct connection.
    b.succeed("iptables -I INPUT -i eth1 -p udp --dport 41641 -j DROP")
    b_ip = b.succeed("tailscale ip -4").strip()

    with subtest("without the rule, tailscale goes through Nebula"):
        a.wait_until_succeeds(f"tailscale ping --c 1 {b_ip} | grep -q 'via 10.99.0.2'", timeout=120)
        print(a.succeed(f"tailscale ping --c 1 {b_ip}"))

    with subtest("with the rule, it doesn't, and the tailnet still works"):
        for m in (a, b):
            m.succeed("ip rule add ${rule}")
        # Make tailscale look for paths again.
        for m in (a, b):
            m.succeed("systemctl restart tailscaled")
        a.wait_until_succeeds(f"ping -c 1 -W 3 {b_ip}", timeout=120)
        a.sleep(30)
        out = a.succeed(f"tailscale ping --c 3 {b_ip} 2>&1 || true")
        print(out)
        assert "via 10.99." not in out, out
        a.succeed(f"ping -c 2 -W 3 {b_ip}")
        # The mesh itself is unaffected.
        a.succeed("ping -c 2 -W 2 10.99.0.2")
  '';
}
