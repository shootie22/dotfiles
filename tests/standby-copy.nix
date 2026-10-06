# The standby copies between the sites (modules/nixos/standby-copy.nix,
# infrastructure #142): fuji pushes a folder to the thinkcentre the way a DK
# service will be pushed to fuji, and the other way round.
#
#   nix build .#checks.x86_64-linux.standby-copy -L
#
# The two machines sit on their mesh addresses directly; Nebula itself is
# covered by tests/nebula-backbone.nix. The key is made at run time, so no
# private key sits in the repo, not even a test one.
{ pkgs }:
let
  lib = pkgs.lib;
  # Stand-in for sops-nix: the key is wherever the test puts it.
  sopsStub = {
    options.sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        freeformType = lib.types.attrs;
        options.path = lib.mkOption { type = lib.types.str; default = "/etc/standby-copy-key"; };
      });
      default = { };
    };
  };
  node = ip: {
    imports = [ ../modules/nixos/standby-copy.nix sopsStub ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ { address = ip; prefixLength = 24; } ];
    networking.firewall.interfaces.eth1.allowedTCPPorts = [ 22 ];
    services.openssh = {
      enable = true;
      openFirewall = false;
      authorizedKeysInHomedir = false;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ "nobody-else" ];
      };
    };
    environment.systemPackages = [ pkgs.sqlite pkgs.rsync ];
    dotfiles.standbyCopy.publicKeys = { fuji = "ssh-ed25519 PLACEHOLDER"; thinkcentre = "ssh-ed25519 PLACEHOLDER"; };
  };
in
pkgs.testers.runNixOSTest {
  name = "standby-copy";

  nodes.fuji = {
    imports = [ (node "10.99.0.2") ];
    users.users.app = { isNormalUser = true; uid = 1000; };
    dotfiles.standbyCopy.send.app = {
      source = "/srv/app";
      to = "thinkcentre";
      sqlite = [ "db/app.sqlite" ];
      exclude = [ "/cache" ];
      interval = "*:0/1";
    };
    # A second job at the same time, as on the real hosts.
    # A glob source, like a local-path volume.
    dotfiles.standbyCopy.send.other = { source = "/srv/oth*"; to = "thinkcentre"; };
  };

  nodes.thinkcentre = {
    imports = [ (node "10.99.0.3") ];
    virtualisation.fileSystems."/srv/standby" = { fsType = "tmpfs"; device = "tmpfs"; };
    dotfiles.standbyCopy.receive = {
      enable = true;
      dir = "/srv/standby";
      from = [ "fuji" ];
      requireMount = "/srv/standby";
    };
  };

  testScript = ''
    start_all()
    fuji.wait_for_unit("multi-user.target")
    thinkcentre.wait_for_unit("sshd.service")

    with subtest("key made at run time, receiver trusts it from fuji only"):
        fuji.succeed("ssh-keygen -q -t ed25519 -N ''' -f /etc/standby-copy-key && chmod 0400 /etc/standby-copy-key")
        pub = fuji.succeed("cut -d' ' -f1,2 /etc/standby-copy-key.pub").strip()
        thinkcentre.succeed(
            "f=/etc/ssh/authorized_keys.d/standby; line=$(cat $f); rm $f; "
            f"echo \"''${{line%ssh-ed25519 PLACEHOLDER}}{pub}\" > $f; chmod 0444 $f; cat $f"
        )

    with subtest("a live folder: owners, a SQLite database being written, an excluded cache"):
        fuji.succeed(
            "mkdir -p /srv/app/db /srv/app/repos/x /srv/app/cache",
            "echo hello > /srv/app/repos/x/file && chown -R app /srv/app/repos && chmod 640 /srv/app/repos/x/file",
            "dd if=/dev/urandom of=/srv/app/repos/x/big bs=1M count=20",
            "echo junk > /srv/app/cache/junk",
            "sqlite3 /srv/app/db/app.sqlite 'pragma journal_mode=wal; create table t (n integer)'",
            "chown app /srv/app/db/app.sqlite",
        )
        fuji.succeed("systemd-run --unit writer sh -c 'while true; do ${pkgs.sqlite}/bin/sqlite3 /srv/app/db/app.sqlite \"insert into t values (1)\"; done'")
        fuji.sleep(2)

    with subtest("copy arrives whole"):
        fuji.succeed("systemctl start standby-copy-app.service")
        d = "/srv/standby/fuji/app"
        thinkcentre.succeed(f"test \"$(cat {d}/repos/x/file)\" = hello")
        thinkcentre.succeed(f"test \"$(stat -c %u:%a {d}/repos/x/file)\" = 1000:640")
        thinkcentre.succeed(f"test \"$(stat -c %u {d}/db/app.sqlite)\" = 1000")
        # Folders keep the source's owner and mode, the snapshot step included.
        fuji.succeed("chown app /srv/app/db && chmod 750 /srv/app/db")
        fuji.succeed("systemctl start standby-copy-app.service")
        for sub in ["", "/db"]:
            want = fuji.succeed(f"stat -c %u:%a /srv/app{sub}").strip()
            thinkcentre.succeed(f"test \"$(stat -c %u:%a {d}{sub})\" = {want}")
        thinkcentre.succeed(f"test -s {d}/.standby-copy-ok")
        thinkcentre.fail(f"test -e {d}/cache")
        thinkcentre.fail(f"test -e {d}/db/app.sqlite-wal")
        thinkcentre.succeed(f"test \"$(sqlite3 {d}/db/app.sqlite 'pragma integrity_check')\" = ok")
        rows = int(thinkcentre.succeed(f"sqlite3 {d}/db/app.sqlite 'select count(*) from t'"))
        assert rows > 0, rows
        print(f"rows in the copy: {rows}")
        fuji.succeed("grep -q 'standby_copy_last_success_timestamp_seconds{copy=\"app\",to=\"thinkcentre\"}' /var/lib/node-exporter-textfile/standby_copy_app.prom")

    with subtest("two jobs at once"):
        fuji.succeed("mkdir -p /srv/other && dd if=/dev/urandom of=/srv/other/big bs=1M count=50")
        # One systemctl call starts both at once and waits for both.
        fuji.succeed("systemctl start standby-copy-other.service standby-copy-app.service")
        thinkcentre.succeed("test -s /srv/standby/fuji/other/big")

    with subtest("deletes follow, and the timer keeps it going"):
        fuji.succeed("rm -r /srv/app/repos/x/big")
        fuji.succeed("systemctl start standby-copy-app.service")
        thinkcentre.fail("test -e /srv/standby/fuji/app/repos/x/big")
        fuji.succeed("systemctl is-active standby-copy-app.timer")

    with subtest("the key can only write into fuji's folder"):
        sshe = "ssh -i /etc/standby-copy-key -o BatchMode=yes -o UserKnownHostsFile=/var/lib/standby-copy/known_hosts"
        ssh = f"{sshe} standby@10.99.0.3"
        fuji.fail(f"{ssh} id")
        fuji.fail(f"{ssh} cat /etc/shadow")
        fuji.succeed("echo x > /tmp/x")
        fuji.fail(f"rsync -e '{sshe}' /tmp/x standby@10.99.0.3:../escaped")
        thinkcentre.fail("test -e /srv/standby/escaped")
        # Reading back isn't allowed either (write-only).
        fuji.fail(f"rsync -e '{sshe}' standby@10.99.0.3:app/repos/x/file /tmp/back")

    with subtest("no standby disk, no copy"):
        thinkcentre.succeed("umount /srv/standby")
        fuji.fail("systemctl start standby-copy-app.service")
        thinkcentre.fail("test -e /srv/standby/fuji")
  '';
}
