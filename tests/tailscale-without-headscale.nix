# Does a tailscale node get back onto the tailnet after a reboot while
# Headscale is down? Decides whether etcd over the tailnet can come back
# without Headscale (infrastructure #37, Phase 3).
#
# Result (2026-10-05, tailscale 1.102): no. The rebooted node comes up
# without its tailnet address and can't reach anyone until Headscale is back;
# nodes that stayed up keep working. Run with:
#   nix build -L --impure --expr 'let f = builtins.getFlake (toString ./.); in import ./tests/tailscale-without-headscale.nix { pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux; }'
{ pkgs }:
let
  tls-cert = pkgs.runCommand "selfSignedCerts" { buildInputs = [ pkgs.openssl ]; } ''
    openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
      -days 365 -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    mkdir -p $out; cp key.pem cert.pem $out
  '';
  client = { ... }: {
    services.tailscale.enable = true;
    security.pki.certificateFiles = [ "${tls-cert}/cert.pem" ];
    networking.firewall.enable = false;
    virtualisation.vlans = [ 1 ];
  };
in
pkgs.testers.runNixOSTest {
  name = "tailscale-without-headscale";
  nodes = {
    headscale = { ... }: {
      virtualisation.vlans = [ 1 ];
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
          sslCertificate = "${tls-cert}/cert.pem";
          sslCertificateKey = "${tls-cert}/key.pem";
          locations."/" = { proxyPass = "http://127.0.0.1:8080"; proxyWebsockets = true; };
        };
      };
      environment.systemPackages = [ pkgs.headscale ];
    };
    a = client;
    b = client;
  };
  testScript = ''
    start_all()
    headscale.wait_for_unit("headscale")
    headscale.wait_for_open_port(443)
    headscale.succeed("headscale users create test")
    uid = headscale.succeed("headscale users list -o json | ${pkgs.jq}/bin/jq -r '.[0].id'").strip()
    key = headscale.succeed(f"headscale preauthkeys -u {uid} create --reusable").strip().split()[-1]
    for c in (a, b):
        c.wait_for_unit("tailscaled")
        c.succeed(f"tailscale up --login-server https://headscale --auth-key {key}")
    b_ip = b.succeed("tailscale ip -4").strip()
    a.wait_until_succeeds(f"tailscale ping --c 1 {b_ip}", timeout=60)
    a_ip_before = a.succeed("tailscale ip -4").strip()
    print("tailnet up:", a_ip_before, b_ip)

    with subtest("Headscale down, a reboots"):
        headscale.succeed("systemctl stop headscale nginx")
        a.shutdown()
        a.start()
        a.wait_for_unit("tailscaled")
        a.sleep(60)
        print("a status:", a.execute("tailscale status 2>&1 | head -5")[1])
        print("a tailscale0:", a.execute("ip -4 addr show dev tailscale0 2>&1")[1])
        has_ip = a.execute(f"ip -4 addr show dev tailscale0 | grep -q {a_ip_before}")[0] == 0
        reaches_b = a.execute(f"ping -c 2 -W 3 {b_ip}")[0] == 0
        print(f"RESULT: address back without Headscale: {has_ip}; reaches b: {reaches_b}")

    with subtest("b (not rebooted) still reaches nothing new, but keeps its own address"):
        print("b tailscale0:", b.execute("ip -4 addr show dev tailscale0 2>&1")[1])

    with subtest("Headscale back: a recovers"):
        headscale.succeed("systemctl start headscale nginx")
        a.wait_until_succeeds(f"ping -c 1 -W 3 {b_ip}", timeout=180)
        print("RESULT: a back on the tailnet once Headscale returns")
  '';
}
