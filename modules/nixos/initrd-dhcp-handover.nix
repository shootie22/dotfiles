# For hosts that unlock their disk over SSH in the initrd and use
# NetworkManager afterwards.
#
# The initrd gets an IPv4 lease for remote unlock, and the address survives
# into stage 2 with that lease's lifetime. NetworkManager then sees the NIC as
# "connected (externally)" and never runs DHCP itself, so when the initrd
# lease expires the LAN address disappears. That took every public site down
# on 2026-10-01 (infrastructure repo, docs/incidents). Drop the initrd's IPv4
# before NetworkManager starts, and declare a DHCP profile for the NIC, so
# NetworkManager always manages it from scratch.
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
      description = "Drop the IPv4 address left over from the initrd";
      wantedBy = [ "NetworkManager.service" ];
      before = [ "NetworkManager.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.iproute2}/bin/ip -4 addr flush dev ${nic}";
      };
    };
  };
}
