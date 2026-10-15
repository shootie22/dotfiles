# Rehearsal of modules/nixos/switch-guard.nix (infrastructure incident
# 2026-10-14: a deploy cut fuji off, and nothing could undo it remotely).
#
#   nix build .#checks.x86_64-linux.switch-guard -L
#
# Steps:
#   1. the system running when the guard starts becomes the known-good one
#   2. a harmless deploy becomes the known-good one after it has run healthy
#   3. a deploy that cuts the host off from every peer is rolled back by
#      itself, comin is held, and the alert arrives once the network is back
#   4. comin stays off until the hold is cleared by hand
#   5. losing the network on the known-good system (no deploy involved)
#      changes nothing
{ pkgs }:

let
  lib = pkgs.lib;
  relay = pkgs.writeText "relay.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            with open("/tmp/alerts", "ab") as f:
                f.write(body + b"\n")
            self.send_response(200)
            self.end_headers()
        def log_message(self, *a):
            pass
    HTTPServer(("0.0.0.0", 9190), H).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "switch-guard";

  nodes = {
    # Stands in for the other servers: answers pings, and is the alert relay.
    peer = { ... }: {
      networking.firewall.allowedTCPPorts = [ 9190 ];
      systemd.services.relay = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${relay}";
      };
    };

    guarded = { nodes, ... }: let peerIP = nodes.peer.networking.primaryIPAddress; in {
      imports = [ ../modules/nixos/switch-guard.nix ];
      environment.systemPackages = [ pkgs.iptables ];
      dotfiles.switchGuard = {
        enable = true;
        peers = [ peerIP ];
        interval = 5;
        failAfter = 20;
        acceptAfter = 15;
        relayUrls = [ "http://${peerIP}:9190/alert" ];
      };
      # A stand-in for comin, so the hold has something to hold.
      systemd.services.comin = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };

      # A harmless change.
      specialisation.fine.configuration.environment.etc."deploy-marker".text = "fine";
      # A change that cuts the host off from every peer while it runs, the
      # way fuji was on 2026-10-14. Gone again once the system without it is
      # switched to (its unit stops and takes the rule with it).
      specialisation.bad.configuration = {
        environment.etc."deploy-marker".text = "bad";
        systemd.services.cut-off = {
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.iptables ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
          script = "iptables -I OUTPUT -d ${peerIP} -j REJECT";
          preStop = "iptables -D OUTPUT -d ${peerIP} -j REJECT";
        };
      };
    };
  };

  testScript = { nodes, ... }: let peerIP = nodes.peer.networking.primaryIPAddress; in ''
    import time

    def current():
        return guarded.succeed("readlink -f /run/current-system").strip()

    def good():
        return guarded.succeed("cat /var/lib/switch-guard/good").strip()

    start_all()
    peer.wait_for_unit("relay.service")
    guarded.wait_for_unit("comin.service")

    with subtest("1. the running system becomes the known-good one"):
        guarded.wait_until_succeeds('[ "$(cat /var/lib/switch-guard/good)" = "$(readlink -f /run/current-system)" ]', timeout=180)
        base = current()
        guarded.succeed("test -L /nix/var/nix/gcroots/switch-guard-good")

    with subtest("2. a harmless deploy becomes known good after running healthy"):
        guarded.succeed(f"{base}/specialisation/fine/bin/switch-to-configuration test")
        fine = current()
        assert fine != base
        assert good() == base, "accepted too early"
        guarded.wait_until_succeeds(f'[ "$(cat /var/lib/switch-guard/good)" = "{fine}" ]', timeout=120)

    with subtest("3. a deploy that cuts the host off is rolled back by itself"):
        t0 = time.time()
        guarded.succeed(f"{base}/specialisation/bad/bin/switch-to-configuration test")
        guarded.succeed("grep -qx bad /etc/deploy-marker")
        guarded.fail("ping -c 1 -W 2 ${peerIP}")
        guarded.wait_until_succeeds(f'[ "$(readlink -f /run/current-system)" = "{fine}" ]', timeout=240)
        print(f"TIME rolled back {time.time() - t0:.0f} s after the bad deploy")
        guarded.succeed("grep -qx fine /etc/deploy-marker")
        guarded.succeed("ping -c 1 -W 2 ${peerIP}")
        guarded.succeed("test -e /var/lib/switch-guard/hold")
        guarded.fail("systemctl is-active comin")
        peer.wait_until_succeeds("grep -q 'Deploy rolled back on guarded' /tmp/alerts", timeout=120)
        print(peer.succeed("cat /tmp/alerts"))

    with subtest("4. comin stays off until the hold is cleared"):
        guarded.succeed("systemctl start comin || true")
        guarded.fail("systemctl is-active comin")
        guarded.succeed("rm /var/lib/switch-guard/hold && systemctl start comin")
        guarded.succeed("systemctl is-active comin")

    with subtest("5. no deploy, no rollback: losing the network on the known-good system"):
        guarded.wait_until_succeeds(f'[ "$(cat /var/lib/switch-guard/good)" = "{fine}" ]', timeout=60)
        guarded.succeed("iptables -I OUTPUT -d ${peerIP} -j REJECT")
        time.sleep(45)
        assert current() == fine, "rolled back without a deploy"
        guarded.fail("test -e /var/lib/switch-guard/hold")
        guarded.succeed("systemctl is-active comin")
        guarded.succeed("iptables -D OUTPUT -d ${peerIP} -j REJECT")
  '';
}
