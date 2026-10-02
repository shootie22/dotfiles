# edge: the small public VPS. It runs no services: it holds the third etcd
# vote, passes TCP through to Traefik in RO and DK, and runs the failover
# checkers (docs/ha in the infrastructure repo). It must be replaceable in
# minutes, so everything about it lives here; its only state is the SSH host
# key, kept encrypted in secrets/edge-bootstrap.yaml. See README.md.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (import ./disko.nix { device = "/dev/sda"; })
    ../../modules/nixos/comin.nix
    ./haproxy.nix
    ../../modules/nixos/failover-checker
    ../../modules/nixos/game-relay.nix
    ../../modules/nixos/alert-relay
    ../../modules/nixos/dnssec-check
  ];

  networking.hostName = "edge";
  time.timeZone = "UTC";

  # Boot ------------------------------------------------------------------
  # GRUB on both the BIOS boot partition and the ESP (see disko.nix).
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Network ---------------------------------------------------------------
  # Plain DHCP on whatever NIC the provider gives us, so the config doesn't
  # depend on interface names.
  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.networks."10-uplink" = {
    matchConfig.Name = "en* eth*";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "routable";
  };
  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

  # Public ports are opened explicitly as the edge gets jobs. SSH only for now.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # SSH -------------------------------------------------------------------
  services.openssh = {
    enable = true;
    openFirewall = false;
    # Logins are granted only by lib/admin-ssh-keys.nix, never by hand.
    authorizedKeysInHomedir = false;
    # Only the ed25519 key: it's the one kept in secrets/edge-bootstrap.yaml,
    # so the host keeps its identity across reinstalls.
    hostKeys = [
      { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "edge" ];
    };
  };

  users.mutableUsers = false;
  users.users.edge = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = builtins.attrValues (import ../../lib/admin-ssh-keys.nix);
  };
  # No passwords on this host at all; SSH keys are the only way in, and
  # remote rebuilds need sudo without a prompt.
  security.sudo.wheelNeedsPassword = false;

  # Secrets ---------------------------------------------------------------
  # The age identity comes from the SSH host key (ssh-to-age), so there is no
  # separate age key to keep.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = ../../secrets/edge.yaml;
  sops.secrets.tailscale_authkey = { };

  # Tailnet ---------------------------------------------------------------
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_authkey.path;
    extraUpFlags = [
      "--login-server=https://hs.radunenu.com"
      "--hostname=edge"
    ];
    # Keep the edge's own DNS independent from the tailnet control plane.
    extraSetFlags = [ "--accept-dns=false" ];
  };

  # Sends alerts to the phone: Pushover, then ntfy (infrastructure repo,
  # docs/ha/alerting.md).
  dotfiles.alertRelay.enable = true;

  # Hourly DNSSEC check of the multi-signer zones, through the relay.
  dotfiles.dnssecCheck.enable = true;

  # Game ports, relayed to the thinkcentre, for when games.radunenu.com points
  # here during a failover.
  dotfiles.gameRelay.enable = true;

  # The edge's vote for failover (infrastructure repo, docs/ha/failover.md).
  # Dry run: it only logs what it would do.
  dotfiles.failoverChecker = {
    enable = true;
    peers = [ "http://100.64.0.2:9180/" ];
  };

  # Housekeeping ----------------------------------------------------------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    # Lets admin devices push closures for remote rebuilds.
    trusted-users = [ "@wheel" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  services.journald.settings.Journal.SystemMaxUse = "500M";

  environment.systemPackages = with pkgs; [ vim git htop ];

  users.motd = "edge: deployed by comin from github.com/shootie22/dotfiles. Change it there, not here.\n";

  system.stateVersion = "26.05";
}
