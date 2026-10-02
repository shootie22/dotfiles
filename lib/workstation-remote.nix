# Wake and unlock the workstation from anywhere (infrastructure repo, #106).
# The workstation is on the DK LAN and usually off. Wake-on-LAN only works
# inside that LAN, so the magic packet is sent from mixi, and the unlock goes
# *through* mixi (ProxyJump) with this device's own key: mixi forwards the
# connection and holds no key for the workstation.
{ pkgs }:

let
  mixi = "mixa@100.64.0.2";
  ip = "192.168.88.176";
  mac = "fc:aa:14:71:89:7c";
in
[
  (pkgs.writeShellScriptBin "workstation-wake" ''
    exec ssh ${mixi} nix shell nixpkgs#wakeonlan -c wakeonlan -i 192.168.88.255 ${mac}
  '')
  # The initrd has its own host key, so it gets its own known_hosts alias.
  (pkgs.writeShellScriptBin "workstation-unlock" ''
    exec ssh -J ${mixi} -p 2222 -o HostKeyAlias=workstation-initrd root@${ip} "$@"
  '')
]
