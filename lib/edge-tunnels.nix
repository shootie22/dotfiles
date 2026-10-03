# Reverse SSH tunnels from the sites to the edge (infrastructure #103): a way
# into fuji and mixi, and into their initrd to unlock the disk, that doesn't
# depend on the tailnet. Shared by both ends: modules/nixos/edge-tunnel.nix
# on the hosts, hosts/edge/tunnels.nix on the edge, lib/edge-tunnel-remote.nix
# on the admin devices.
#
# port: where the tunnel listens on the edge, loopback only.
# key:  the public key allowed to listen there. Each host generates its own
#       on first activation and writes the public half to
#       /etc/ssh/edge-tunnel/<name>.pub. null until it's been copied here.
{
  mixi = { port = 2201; key = null; };
  mixi-initrd = { port = 2202; key = null; };
  fuji = { port = 2211; key = null; };
  fuji-initrd = { port = 2212; key = null; };
}
