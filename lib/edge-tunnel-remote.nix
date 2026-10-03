# Ways in that don't need the tailnet (infrastructure #103, docs/remote-access.md
# in the infrastructure repo):
#
#   via-edge <host>         SSH to fuji or mixi through its reverse tunnel on the edge
#   unlock-via-edge <host>  same, into the initrd: asks for the disk passphrase
#                           and continues the boot (systemctl default)
#   mixi-unlock             unlock mixi from inside the DK LAN, jumping through
#                           the thinkcentre (needs the tailnet, not the edge)
#
# The edge and the jump hosts only pass the connection along; the login is
# end to end with this device's own key. Host keys are checked under the
# same names as over the tailnet, so a wrong machine on the other end of a
# tunnel fails the check.
{ pkgs }:

let
  tunnels = import ./edge-tunnels.nix;
  # The edge by its public name (no tailnet needed), checked against the key
  # it has on the tailnet.
  viaEdge = ''-o ProxyCommand="ssh -o HostKeyAlias=100.64.0.9 -W %h:%p edge@edge.radunenu.com"'';
  # Sets port, user and alias (the host key name used over the tailnet).
  pickHost = suffix: ''
    case "''${1:-}" in
      mixi) port=${toString tunnels."mixi${suffix}".port} user=mixa alias=100.64.0.2 ;;
      fuji) port=${toString tunnels."fuji${suffix}".port} user=fuji alias=100.64.0.1 ;;
      *) echo "usage: $(basename "$0") <mixi|fuji> [ssh args]" >&2; exit 2 ;;
    esac
    host=$1; shift
  '';
in
[
  (pkgs.writeShellScriptBin "via-edge" ''
    ${pickHost ""}
    exec ssh ${viaEdge} -p "$port" -o HostKeyAlias="$alias" "$user@127.0.0.1" "$@"
  '')
  # The initrd has its own host key, so it gets its own known_hosts alias.
  (pkgs.writeShellScriptBin "unlock-via-edge" ''
    ${pickHost "-initrd"}
    [ $# -gt 0 ] || set -- systemctl default
    exec ssh -t ${viaEdge} -p "$port" -o HostKeyAlias="$host-initrd" root@127.0.0.1 "$@"
  '')
  (pkgs.writeShellScriptBin "mixi-unlock" ''
    [ $# -gt 0 ] || set -- systemctl default
    exec ssh -t -J main@100.64.0.4 -p 2222 -o HostKeyAlias=mixi-initrd root@192.168.88.173 "$@"
  '')
]
