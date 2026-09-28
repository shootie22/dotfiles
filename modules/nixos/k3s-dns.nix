# Pods take their search domains from the kubelet's resolv.conf, which is the
# host's by default. Tailnet DNS on a host adds `search tail.radunenu.com`,
# and *.radunenu.com is a public wildcard: with ndots:5 almost every name a pod
# looks up (github.com, git.radunenu.com, even cluster Service FQDNs) was tried
# as <name>.tail.radunenu.com first and resolved to the wildcard.
#
# Give the kubelet a fixed file instead: public resolvers, no search domains.
# CoreDNS uses it as its upstream too, so cluster DNS no longer depends on the
# DNS setup of whichever node CoreDNS runs on.
#
# thinkcentre (Debian) carries the same file in hosts/thinkcentre/.
{ ... }:

{
  environment.etc."k3s-resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 9.9.9.9
    nameserver 8.8.8.8
  '';

  services.k3s.extraFlags = [ "--resolv-conf=/etc/k3s-resolv.conf" ];
}
