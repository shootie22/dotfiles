# Public raw TCP/UDP edge for services hosted on the thinkcentre. The router
# forwards these ports to fuji; fuji relays them over the tailnet. The port
# list is shared with the edge VPS in modules/nixos/game-relay.nix.
{ ... }:

{
  imports = [ ../../modules/nixos/game-relay.nix ];

  dotfiles.gameRelay = {
    enable = true;
    interface = "eno1";
  };
}
