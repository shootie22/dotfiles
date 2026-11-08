# The dotfiles build cache (Attic): GitHub Actions builds every host's system
# and pushes it here, and the hosts download it instead of building it
# themselves. mixi (Asahi) and minima-vm (16K pages) compiled their own
# kernel after every nixpkgs update; comin killed those builds or they ran
# for hours, filled the disk and took memory from the pods, and both hosts
# stopped deploying (2026-11-05). .github/workflows/build.yaml fills it.
#
# Only on the tailnet: hosts and the CI runners (headscale user "ci", which
# the ACL lets reach this port only) talk to it over WireGuard, and nothing
# outside can reach it, since mixi's Asahi firmware (not redistributable) is
# in it. Inside the tailnet, reading needs no token; pushing does.
#
# The server only has the public half of the RS256 key that signs tokens, so
# it can check tokens but never make them; the private half stays on Radu's
# workstation (~/.config/attic-keys, minted there with atticadm make-token).
# Old store paths go after 30 days; what the hosts run now gets pushed again
# with every build.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.buildCache;
  storage = "/home/main/storage/attic";
in
{
  options.dotfiles.buildCache.server.enable = lib.mkEnableOption "the Attic build cache on this host";

  config = lib.mkIf cfg.server.enable {
    services.atticd = {
      enable = true;
      # Not secret: the public half only. A token made with the private half
      # is all a client needs.
      environmentFile = pkgs.writeText "atticd.env" ''
        ATTIC_SERVER_TOKEN_RS256_PUBKEY_BASE64=LS0tLS1CRUdJTiBSU0EgUFVCTElDIEtFWS0tLS0tCk1JSUNDZ0tDQWdFQXVZaWlaeWhQQ1BGWVgxYzM5Wm14U0NIcmdXNmRFc0xudVhyZ1JPcDJ5MldsWnVLaFg1MDMKcVRGUHB1SkVWMG5sODJvczVXOTZqMDVzc3h6Qlk2R1dIaXJ2cUZQSFJLNXI5ZGE0bno2c0xJc0p0bVBNSjZGeApJOTh6YW9uNkxmYkpJTVF1WUhzOXl0RCthZTlESzVYMXMvQ3dPbFFOZGZnY01QajlySmRSM2wyM1IxS2F0TTBuClc0ZGVON04vMmZLL2FIeGZ4MHVPZEQ0YUN1aW5wVC9KRW9FblBwOWsvNHVmSXhlejA1YzF6QmNCY2NCMnBUV3gKdTdqcjhTaktoSzFSbVV6UVpKMkYvTUpmeitVVXltaTA5eUo2ZU85YWoxMTF4elA0SGgwWlBIUkpHdy8wWXZIbgpBVXg4VHJXU1hJRVZhOE1vUTgwd3dvWWJuSFFHOUV4N0R1b0tPaWhUa0lLai9WUW51YUROV0JjdFI2M0RSb0FUCnJjRXI2dzlvSjUzcUwxMDB5SGY4WFdLa2dFN1ZaZUYvK0dRSGZGc1Q5SnB2aDYzL3lEeU52R2lubkpFS2RnWFQKN2lTUmI1TFRrWWdyWmM1cEJSMmRYTGFkWUNmbzJqZVR0Rlk0MFlIdHNnZEtRWmJ2YVB3WjZzUklCeUNEc2ZVNgpZTWlpYTlIcFc1TitCN3pVNk1UVVdRWnM3a0lEaUY0ZU9Ea2ErV0psZjAzcHFsNzNxMGpFV1AzVVBEL25wOTgwCmxlV1NZS3hsOGR5Sy9IWmRSR3BXcUlBUkltZ2wwNGdJUldFR2xFYjJkNzE3a1dkWmRxQklaa0l5eFBMbFVRbk8Kdy9sRHYweFlHeldndDZja1JCMWRZcUhOTlhnVHN2TmtpWXBkck9sZ1hGQjh6bVBqTXgvMFdmOENBd0VBQVE9PQotLS0tLUVORCBSU0EgUFVCTElDIEtFWS0tLS0tCg==
      '';
      settings = {
        listen = "[::]:8199";
        api-endpoint = "http://100.64.0.4:8199/";
        allowed-hosts = [ "100.64.0.4:8199" ];
        storage = { type = "local"; path = "/var/lib/atticd/storage"; };
        garbage-collection = {
          interval = "12 hours";
          default-retention-period = "30 days";
        };
      };
    };

    # The store goes on the 4 TB disk; the database (small) stays in
    # /var/lib/atticd. A fixed user rather than the module's DynamicUser, so
    # the folder there can belong to it; /home stays hidden except that one
    # folder, bound over the storage path.
    users.users.atticd = { isSystemUser = true; group = "atticd"; };
    users.groups.atticd = { };
    systemd.tmpfiles.rules = [ "d ${storage} 0750 atticd atticd -" ];
    systemd.services.atticd = {
      unitConfig.RequiresMountsFor = [ "/home/main/storage" ];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        ProtectHome = lib.mkForce "tmpfs";
        BindPaths = [ "${storage}:/var/lib/atticd/storage" ];
      };
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8199 ];
  };
}
