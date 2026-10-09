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
  host = "workstation.tail.radunenu.com";

  wake = pkgs.writeShellScriptBin "workstation-wake" ''
    exec ssh ${mixi} nix shell nixpkgs#wakeonlan -c wakeonlan -i 192.168.88.255 ${mac}
  '';
  # The initrd has its own host key, so it gets its own known_hosts alias.
  unlock = pkgs.writeShellScriptBin "workstation-unlock" ''
    exec ssh -J ${mixi} -p 2222 -o HostKeyAlias=workstation-initrd root@${ip} "$@"
  '';
in
[
  wake
  unlock
  # Moonlight to the workstation's Sunshine (modules/nixos/game-streaming.nix),
  # waking and unlocking it first if it's off. App defaults to the desktop:
  #   workstation-stream ["Steam Big Picture"]
  (pkgs.writeShellScriptBin "workstation-stream" ''
    set -u
    export PATH=${pkgs.lib.makeBinPath [ pkgs.netcat pkgs.openssh pkgs.coreutils ]}:$PATH
    app=''${1:-Desktop}
    up() { nc -z -w 3 ${host} "$1" 2>/dev/null; }
    wait_for() {  # wait_for <what> <seconds> <command...>
      what=$1 secs=$2; shift 2
      printf 'Waiting for %s' "$what"
      for _ in $(seq "$((secs / 5))"); do
        if "$@"; then echo; return 0; fi
        printf .; sleep 5
      done
      echo; echo "Gave up waiting for $what." >&2; exit 1
    }

    if ! up 47989; then
      if up 22; then
        echo "The workstation is up but Sunshine isn't answering." >&2
        echo "Check: ssh nixa@${host} systemctl --user status sunshine" >&2
        exit 1
      fi
      ${wake}/bin/workstation-wake
      # The initrd's SSH, as seen from mixi on the same LAN.
      wait_for "the unlock prompt" 180 \
        ssh -o ConnectTimeout=5 ${mixi} "bash -c '</dev/tcp/${ip}/2222' 2>/dev/null"
      ${unlock}/bin/workstation-unlock
      wait_for "Sunshine" 180 up 47989
    fi

    exec ${pkgs.moonlight-qt}/bin/moonlight stream ${host} "$app"
  '')
]
