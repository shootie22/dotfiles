# Reverse SSH tunnel to the edge (infrastructure #103). Keeps a connection
# open to the edge and makes this machine's sshd reachable there on a
# loopback port, so an admin device can get in through the edge
# (`via-edge <host>`) when the tailnet is broken. Optionally the same from
# the initrd, for unlocking the disk after a reboot (`unlock-via-edge`).
#
# The tunnel keys can only listen on their own port on the edge, nothing
# else; they don't open any machine. Admin devices still log in end to end
# with their own keys, the edge only passes the bytes along.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.edgeTunnel;
  name = config.networking.hostName;
  tunnels = import ../../lib/edge-tunnels.nix;
  edgeHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAH0lgd5bZxAuENorPG4wHMmVNS4W4GkGAqAJ+bIgKSH";

  keyDir = "/etc/ssh/edge-tunnel";
  key = "${keyDir}/id_ed25519";
  initrdKey = "/etc/secrets/initrd/edge_tunnel_ed25519";

  knownHosts = pkgs.writeText "edge-known-hosts" "edge ${edgeHostKey}\n";
  # The initrd has no usable resolver, so it connects by address. Update it
  # when the edge moves (docs/ha/runbooks/replace-edge.md).
  edgeAddress = "141.95.67.178";

  sshConfig = host: port: target: pkgs.writeText "edge-tunnel-config" ''
    Host edge
      HostName ${host}
      HostKeyAlias edge
      User tunnel
      RemoteForward 127.0.0.1:${toString port} ${target}
      StrictHostKeyChecking yes
      BatchMode yes
      IdentitiesOnly yes
      ExitOnForwardFailure yes
      ConnectTimeout 15
      ServerAliveInterval 30
      ServerAliveCountMax 3
  '';

  sshPort = builtins.head config.services.openssh.ports;
  initrdPort = config.boot.initrd.network.ssh.port;
in
{
  options.dotfiles.edgeTunnel = {
    enable = lib.mkEnableOption "the reverse SSH tunnel to the edge";
    initrd = lib.mkEnableOption ''
      the tunnel from the initrd too. Turn it on only after the host has
      generated ${initrdKey} (first activation with `enable`), otherwise the
      bootloader install fails on the missing file
    '';
  };

  config = lib.mkIf cfg.enable {
    # Generate the keys on first activation. The public halves are readable
    # by anyone, so they can be copied into lib/edge-tunnels.nix.
    system.activationScripts.edgeTunnelKeys = ''
      install -d -m 755 ${keyDir}
      install -d -m 700 /etc/secrets/initrd
      for k in ${key}:${name} ${initrdKey}:${name}-initrd; do
        file=''${k%%:*}; label=''${k#*:}
        if [ ! -f "$file" ]; then
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "$label" -f "$file"
          rm -f "$file.pub"
        fi
        ${pkgs.openssh}/bin/ssh-keygen -y -f "$file" > ${keyDir}/$label.pub
        chmod 644 ${keyDir}/$label.pub
      done
    '';

    systemd.services.edge-tunnel = {
      description = "Reverse SSH tunnel to the edge";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "sshd.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        DynamicUser = true;
        LoadCredential = [ "identity:${key}" ];
        ExecStart = "${pkgs.openssh}/bin/ssh -F ${sshConfig "edge.radunenu.com" tunnels.${name}.port "127.0.0.1:${toString sshPort}"}"
          + " -o UserKnownHostsFile=${knownHosts} -i %d/identity -NT edge";
        Restart = "always";
        RestartSec = "30s";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    boot.initrd = lib.mkIf cfg.initrd {
      secrets."/etc/ssh/edge-tunnel/id_ed25519" = initrdKey;
      systemd = {
        storePaths = [ "${pkgs.openssh}/bin/ssh" ];
        contents = {
          "/etc/ssh/edge-tunnel/config".source =
            sshConfig edgeAddress tunnels."${name}-initrd".port "127.0.0.1:${toString initrdPort}";
          "/etc/ssh/edge-tunnel/known_hosts".source = knownHosts;
        };
        services.edge-tunnel = {
          description = "Reverse SSH tunnel to the edge, for unlocking the disk";
          wantedBy = [ "initrd.target" ];
          after = [ "network.target" "sshd.service" "initrd-nixos-copy-secrets.service" ];
          before = [ "shutdown.target" ];
          conflicts = [ "shutdown.target" ];
          unitConfig = {
            # Start before the root is unlocked and keep retrying until the
            # network is up; never blocks unlocking from the LAN.
            DefaultDependencies = false;
            StartLimitIntervalSec = 0;
          };
          preStart = "/bin/chmod 0600 /etc/ssh/edge-tunnel/id_ed25519";
          serviceConfig = {
            ExecStart = "${pkgs.openssh}/bin/ssh -F /etc/ssh/edge-tunnel/config"
              + " -o UserKnownHostsFile=/etc/ssh/edge-tunnel/known_hosts"
              + " -o GlobalKnownHostsFile=/dev/null -o IdentityAgent=none"
              + " -i /etc/ssh/edge-tunnel/id_ed25519 -NT edge";
            Restart = "always";
            RestartSec = "10s";
          };
        };
      };
    };
  };
}
