# Runs the Minima NixOS VM (Lima + krunkit) as a boot-time server.
#
# Lima's krunkit driver stops a VM with SIGTERM/SIGKILL to krunkit, which is a
# power cut for the guest (it once left the guest's ESP corrupt). So the VM is
# always stopped from inside: `systemctl poweroff` in the guest, then krunkit
# exits by itself. Never use `limactl stop minima`; use `minima-vm stop`.
{ pkgs, ... }:

let
  user = "radu";
  home = "/Users/${user}";
  instance = "minima";
  limactl = "/opt/homebrew/bin/limactl";
  label = "org.nixos.minima-vm";
  plist = "/Library/LaunchDaemons/${label}.plist";

  supervisor = pkgs.writeShellScript "minima-vm-supervisor" ''
    set -u
    status() { ${limactl} list ${instance} --format '{{.Status}}' 2>/dev/null; }

    stop_guest() {
      echo "$(date '+%F %T') stopping ${instance}: powering off the guest"
      ${limactl} shell --workdir / ${instance} sudo systemctl poweroff || true
      for _ in $(seq 60); do
        [ "$(status)" = Running ] || { echo "$(date '+%F %T') ${instance} is off"; return; }
        sleep 1
      done
      echo "$(date '+%F %T') guest did not power off within 60s; hard stop"
      ${limactl} stop ${instance}
    }

    trap 'stop_guest; exit 0' TERM INT

    if [ "$(status)" = Running ]; then
      # Started outside launchd: supervise it rather than fight it.
      echo "$(date '+%F %T') adopting running ${instance}"
      while [ "$(status)" = Running ]; do sleep 10 & wait $!; done
      exit 1
    fi

    echo "$(date '+%F %T') starting ${instance}"
    ${limactl} start --foreground ${instance} &
    wait $!
    rc=$?
    echo "$(date '+%F %T') ${instance} exited ($rc)"
    exit 1 # the VM should always run; let launchd restart it
  '';

  control = pkgs.writeShellScriptBin "minima-vm" ''
    case "''${1:-}" in
      start)  sudo launchctl bootstrap system ${plist} ;;
      stop)   sudo launchctl bootout system/${label} ;;  # clean guest poweroff
      status) ${limactl} list ${instance}; sudo launchctl print system/${label} | grep -E '^\s*(state|pid|last exit code) =' ;;
      log)    tail -n "''${2:-50}" ${home}/.lima/${instance}/launchd.log ;;
      *) echo "usage: minima-vm start|stop|status|log [lines]" >&2; exit 2 ;;
    esac
  '';
in
{
  # `command` (not ProgramArguments) waits for the /nix/store volume to mount.
  launchd.daemons.minima-vm.command = "${supervisor}";
  launchd.daemons.minima-vm.serviceConfig = {
    Label = label;
    UserName = user;
    GroupName = "staff";
    WorkingDirectory = home;
    EnvironmentVariables = {
      HOME = home;
      # Lima finds krunkit on PATH.
      PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 30;
    # Time for the guest to power off before launchd sends SIGKILL.
    ExitTimeOut = 120;
    StandardOutPath = "${home}/.lima/${instance}/launchd.log";
    StandardErrorPath = "${home}/.lima/${instance}/launchd.log";
  };

  # Bridges the VM's second NIC onto the Ethernet LAN (vmnet needs root).
  # Lima connects to the socket; it must exist before the VM starts, and the
  # VM supervisor simply retries until it does.
  launchd.daemons.socket-vmnet-bridged = {
    command = "${pkgs.socket-vmnet}/bin/socket_vmnet --vmnet-mode=bridged"
      + " --vmnet-interface=en0 --socket-group=staff"
      + " /var/run/socket_vmnet.bridged.en0";
    serviceConfig = {
      Label = "org.nixos.socket-vmnet-bridged";
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/var/log/socket_vmnet.bridged.en0.log";
      StandardErrorPath = "/var/log/socket_vmnet.bridged.en0.log";
    };
  };

  # The instance config lives in this repo; Lima reads it on each VM start.
  system.activationScripts.postActivation.text = ''
    install -m 0644 -o ${user} -g staff ${./lima.yaml} ${home}/.lima/${instance}/lima.yaml
  '';

  environment.systemPackages = [ control ];

  # A server: come back after power loss, never sleep.
  power.restartAfterPowerFailure = true;
  power.sleep.computer = "never";
}
