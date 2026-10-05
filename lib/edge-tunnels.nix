# Reverse SSH tunnels from the sites to the edge (infrastructure #103): a way
# into fuji and mixi, and into their initrd to unlock the disk, that doesn't
# depend on the tailnet. Shared by both ends: modules/nixos/edge-tunnel.nix
# on the hosts, hosts/edge/tunnels.nix on the edge, lib/edge-tunnel-remote.nix
# on the admin devices.
#
# port: where the tunnel listens on the edge, loopback only.
# key:  the public key allowed to listen there. Each host generates its own
#       on first activation and writes the public half to
#       /etc/ssh/edge-tunnel/<name>.pub, which gets copied here.
{
  mixi = { port = 2201; key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH5NmtEWzHy+zg0WXkbU44wcWbdebmo2lkYM4oiCtag5"; };
  mixi-initrd = { port = 2202; key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIAgVxRFMQgYWVSeF4Yqf3gTkwUvIemNYAeAxtPxU/pH"; };
  fuji = { port = 2211; key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4QC7IeqAXpfnIPfPMPEHQjeUKTWtb/H3iqo4EUqEEJ"; };
  fuji-initrd = { port = 2212; key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHX+m0QePnB9VWgcUCwN4tfFz+HbX30aodv98ZfYVK8P"; };
  thinkcentre = { port = 2221; key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH7V94GrjvW9A77JP+laYpx2xUHNZhYfw+SDXEWTB3se"; };
  thinkcentre-initrd = { port = 2222; key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJ0PEdBpILbxvExwi85nv2ZgyPgogD+aWbJJVVVsxN+"; };
}
