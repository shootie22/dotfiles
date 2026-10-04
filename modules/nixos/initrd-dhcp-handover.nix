# For hosts that unlock their disk over SSH in the initrd and use
# NetworkManager afterwards.
#
# The initrd gets an IPv4 lease for remote unlock, and the address survives
# into stage 2 with that lease's lifetime. NetworkManager then sees the NIC as
# "connected (externally)" and never runs DHCP itself, so when the initrd
# lease expires the LAN address disappears. That took every public site down
# on 2026-10-01 (infrastructure repo, docs/incidents). Take the NIC down and
# drop everything the initrd configured on it before NetworkManager starts, and
# declare a DHCP profile for it, so NetworkManager always manages it from
# scratch.
{ config, lib, pkgs, ... }:

let
  nic = config.dotfiles.lanInterface;
in
{
  options.dotfiles.lanInterface = lib.mkOption {
    type = lib.types.str;
    example = "eno1";
    description = "The wired NIC the initrd brings up for remote unlock.";
  };

  config = {
    networking.networkmanager.ensureProfiles.profiles.lan = {
      connection = {
        id = "lan";
        type = "ethernet";
        interface-name = nic;
        autoconnect-priority = 10;
      };
      ethernet = { };
      ipv4.method = "auto";
      ipv6.method = "auto";
    };

    systemd.services.flush-initrd-ipv4 = {
      description = "Drop the addresses left over from the initrd";
      wantedBy = [ "NetworkManager.service" ];
      before = [ "NetworkManager.service" ];
      # Only at boot, before NetworkManager first starts. On a live switch
      # NetworkManager is already running and this would flush the address it
      # manages, cutting the machine off.
      unitConfig.ConditionPathExists = "!/run/NetworkManager";
      serviceConfig = {
        Type = "oneshot";
        # All addresses, not only IPv4, and the link down: if anything is left
        # (IPv6 from router advertisements, say), NetworkManager calls the
        # device "connected (externally)" and never runs DHCP. Found in the
        # thinkcentre rehearsal VM, 2026-10-04.
        ExecStart = [
          "${pkgs.iproute2}/bin/ip link set dev ${nic} down"
          "${pkgs.iproute2}/bin/ip addr flush dev ${nic}"
        ];
      };
    };
  };
}
