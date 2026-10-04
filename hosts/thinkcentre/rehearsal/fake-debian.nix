# Stand-in for Debian in the rehearsal VM: a tiny EFI program (kernel plus a
# busybox initrd) at Debian's shim path. It prints a marker on the serial
# console and powers off, so the harness can tell exactly when a fallback
# landed in "Debian".
{
  runCommand,
  systemdUkify,
  systemd,
  cpio,
  gzip,
  pkgsStatic,
  linuxPackages,
}:

let
  kernel = linuxPackages.kernel;
in
runCommand "fake-debian.efi" { nativeBuildInputs = [ systemdUkify cpio gzip ]; } ''
  mkdir -p root/bin root/dev
  cp ${pkgsStatic.busybox}/bin/busybox root/bin/busybox
  cat > root/init <<'EOF'
  #!/bin/busybox sh
  /bin/busybox mount -t devtmpfs devtmpfs /dev
  echo FAKE-DEBIAN-BOOTED > /dev/console
  /bin/busybox sleep 1
  /bin/busybox poweroff -f
  EOF
  chmod 755 root/init
  (cd root && find . | cpio --quiet -o -H newc | gzip -9) > initrd.gz
  ukify build \
    --linux ${kernel}/${kernel.target} \
    --initrd initrd.gz \
    --cmdline "console=ttyS0,115200 panic=-1" \
    --os-release "ID=fake-debian" \
    --stub ${systemd}/lib/systemd/boot/efi/linuxx64.efi.stub \
    --output $out
''
