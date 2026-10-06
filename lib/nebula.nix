# The servers' Nebula backbone (infrastructure #141, decision 2026-10-05):
# their own overlay, with no control server to ask at boot. Shared by
# modules/nixos/nebula-mesh.nix on every server.
#
# ip:         the host's address on the mesh
# lighthouse: also a lighthouse and a relay (the others find each other
#             through them, and go through them when NAT blocks a direct path)
# reach:      where the others reach a lighthouse. fuji is listed by RO's
#             public name (UDP 4242 forwarded on the router) and by its LAN
#             address, for minima next to it.
# api:        runs the Kubernetes API; every host resolves k3s-api to these
#             (the fixed registration address, infrastructure #21)
# lan:        the site's LAN; hosts next to each other prefer it over
#             anything else.
#
# Certificates are in lib/nebula/: ca.crt, and one per host, signed from the
# public key the host makes on its first activation. The CA key is kept
# privately.
{
  network = "10.99.0.0/24";
  port = 4242;
  hosts = {
    edge = { ip = "10.99.0.1"; lighthouse = true; reach = [ "141.95.67.178:4242" ]; };
    fuji = { ip = "10.99.0.2"; lan = "192.168.100.0/24"; lighthouse = true; api = true; reach = [ "ro.radunenu.com:4242" "192.168.100.136:4242" ]; };
    thinkcentre = { ip = "10.99.0.3"; lan = "192.168.88.0/24"; api = true; };
    mixi = { ip = "10.99.0.4"; lan = "192.168.88.0/24"; };
    minima = { ip = "10.99.0.5"; lan = "192.168.100.0/24"; };
  };
}
