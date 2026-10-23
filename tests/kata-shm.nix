# A Kata-sized VM fits in /dev/shm (modules/nixos/kata.nix). On mixi the CI
# VM (4.5 GiB) was bigger than /dev/shm (half the RAM, 3.7 GiB), so every
# arm64 job died once its guest had touched 3.7 GiB: "kvm run failed Bad
# address" (2026-10-15 to 2026-10-23, infrastructure #300).
#
#   nix build .#checks.x86_64-linux.kata-shm -L
#
# Both machines start a guest the way Kata does (its memory a file in
# /dev/shm, shared), bigger than half their RAM, and fill its memory:
#   - kata: with the module, the guest fills it and shuts down
#   - before: /dev/shm at NixOS's default half, the guest never gets there:
#     it dies (mixi, "kvm run failed Bad address") or, nested in a test
#     VM on x86, hangs until the timeout
{ pkgs }:

let
  lib = pkgs.lib;
  ram = 3072; # MiB, each test machine
  guest = 2048; # MiB, more than half of it
  fill = 1800; # MiB the guest writes into its own memory

  # The guest: a kernel and a shell that fills a tmpfs, i.e. its RAM.
  init = pkgs.writeScript "init" ''
    #!${pkgs.busybox}/bin/sh
    export PATH=${pkgs.busybox}/bin
    mkdir -p /dev /proc
    mount -t devtmpfs dev /dev
    exec >/dev/ttyS0 2>&1
    mount -t proc proc /proc
    mkdir -p /fill
    mount -t tmpfs -o size=${toString fill}m tmpfs /fill
    dd if=/dev/zero of=/fill/zero bs=1M count=${toString fill} 2>/dev/null && echo "guest filled ${toString fill} MiB"
    poweroff -f
  '';
  initrd = pkgs.makeInitrd { contents = [{ object = init; symlink = "/init"; }]; };
  kernel = pkgs.linuxPackages.kernel;

  # Kata's QEMU memory options (-m with memory-backend-file on /dev/shm,
  # share=on), as on the CI nodes.
  runGuest = pkgs.writeShellScript "run-guest" ''
    ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
      -machine q35,accel=kvm:tcg -cpu max -smp 2 -m ${toString guest}M \
      -object memory-backend-file,id=dimm1,size=${toString guest}M,mem-path=/dev/shm,share=on \
      -numa node,memdev=dimm1 \
      -kernel ${kernel}/bzImage -initrd ${initrd}/initrd \
      -append "console=ttyS0 panic=-1 quiet" \
      -display none -serial file:/tmp/guest-console -no-reboot </dev/null
    status=$?
    cat /tmp/guest-console
    exit $status
  '';

  machine = extra: { ... }: {
    imports = [ ../modules/nixos/kata.nix extra ];
    dotfiles.kata.enable = true;
    virtualisation.memorySize = ram;
    virtualisation.cores = 2;
  };
in
pkgs.testers.runNixOSTest {
  name = "kata-shm";

  nodes = {
    kata = machine { };
    before = machine { boot.devShmSize = "50%"; };
  };

  testScript = ''
    def shm_mib(m):
        return int(m.succeed("df -m --output=size /dev/shm | tail -1"))

    start_all()
    for m in (kata, before):
        m.wait_for_unit("multi-user.target")

    with subtest("/dev/shm holds the whole guest with the module"):
        assert shm_mib(kata) > ${toString guest}, f"/dev/shm is {shm_mib(kata)} MiB"
        out = kata.succeed("timeout 300 ${runGuest} 2>&1")
        print(out)
        assert "guest filled ${toString fill} MiB" in out, "the guest didn't fill its memory"

    with subtest("at half the RAM the same guest never fills it, as on mixi"):
        assert shm_mib(before) < ${toString guest}, f"/dev/shm is {shm_mib(before)} MiB"
        status, out = before.execute("timeout 120 ${runGuest} 2>&1")
        print(out)
        assert "guest filled" not in out, "the guest fit; the test no longer shows the failure"
  '';
}
