#!/usr/bin/env bash
# VM test of the trial boot's first hop: Debian's real shim + signed GRUB
# (same versions as the thinkcentre), Debian's boot-once logic from 00_header,
# and our NixOS entry chainloading systemd-boot from the ESP.
#   A: next_entry=nixos, systemd-boot present  -> systemd-boot boots the UKI
#   B: next_entry=nixos, systemd-boot missing  -> GRUB reboots by itself
#   C: the boot after B                        -> Debian's entry
# Usage (needs qemu, dosfstools, mtools, e2fsprogs, util-linux, grub2, dpkg,
# curl, and OVMF_CODE/OVMF_VARS set):
#   grub-chain-test.sh <systemd-bootx64.efi> <fake-debian.nix UKI> grub-40_custom
# All three cases passed on 2026-10-05.
set -euo pipefail
SDBOOT=$1 UKI=$2 CUSTOM=$3
W=$(mktemp -d) ; cd "$W"
ESP_UUID=4A5A55D9
BOOT_UUID=3a0ee5c4-126d-4405-a302-619255d511eb
DEB_ID='gnulinux-advanced-acead032-ccba-4001-907f-1c7f12b35b73>gnulinux-6.12.63+deb13-amd64-advanced-acead032-ccba-4001-907f-1c7f12b35b73'

fetch() { # package version
  local p=$1 v=$2 f
  f="${p}_${v}_amd64.deb"
  for base in https://deb.debian.org/debian/pool/main https://security.debian.org/debian-security/pool/updates/main; do
    curl -fsSL -o "$f" "$base/${p:0:1}/${3:-$p}/$f" && { dpkg-deb -x "$f" deb; return; }
  done
  echo "could not download $f" >&2; exit 1
}
fetch grub-efi-amd64-signed '1+2.12+9+deb13u2'
fetch shim-signed '1.51~1+deb13u1+16.1-2~deb13u1' shim-signed
SHIM=$(find deb -name 'shimx64.efi.signed' | head -1)
GRUBX=$(find deb -name 'grubx64.efi.signed' | head -1)
echo "shim: $SHIM  grub: $GRUBX"

# ESP contents, laid out like Debian's
mkdir -p esp/EFI/BOOT esp/EFI/debian esp/EFI/systemd esp/EFI/Linux
cat > stub.cfg <<EOF
search.fs_uuid $BOOT_UUID root
set prefix=(\$root)'/grub'
configfile \$prefix/grub.cfg
EOF
for d in BOOT debian; do cp stub.cfg esp/EFI/$d/grub.cfg; cp "$GRUBX" esp/EFI/$d/grubx64.efi; done
cp "$SHIM" esp/EFI/BOOT/BOOTX64.EFI
cp "$SHIM" esp/EFI/debian/shimx64.efi
cp "$UKI" esp/EFI/Linux/nixos-fake.efi
mkdir -p esp/loader ; printf 'timeout 0\n' > esp/loader/loader.conf

# Debian's /boot: the generated header, Debian's entries as stand-ins, our entry
mkdir -p boot/grub
{
  cat <<'EOF'
if [ -s $prefix/grubenv ]; then
  set have_grubenv=true
  load_env
fi
if [ "${next_entry}" ] ; then
   set default="${next_entry}"
   set next_entry=
   save_env next_entry
   set boot_once=true
else
   set default="${saved_entry}"
fi
set timeout=5
submenu 'Advanced options for Debian GNU/Linux' --id gnulinux-advanced-acead032-ccba-4001-907f-1c7f12b35b73 {
  menuentry 'Debian GNU/Linux, with Linux 6.12.63+deb13-amd64' --id gnulinux-6.12.63+deb13-amd64-advanced-acead032-ccba-4001-907f-1c7f12b35b73 {
    echo DEBIAN-ENTRY-CHOSEN
    sleep 2
    halt
  }
}
EOF
  echo '### BEGIN /etc/grub.d/40_custom ###'
  tail -n +3 "$CUSTOM"
  echo '### END /etc/grub.d/40_custom ###'
} > boot/grub/grub.cfg

mkdisk() { # with_sdboot next_entry
  rm -f disk.img esp.img bootp.img
  rm -f esp/EFI/systemd/systemd-bootx64.efi
  [ "$1" = yes ] && cp "$SDBOOT" esp/EFI/systemd/systemd-bootx64.efi
  rm -f boot/grub/grubenv
  grub-editenv boot/grub/grubenv create
  grub-editenv boot/grub/grubenv set "saved_entry=$DEB_ID"
  [ -n "$2" ] && grub-editenv boot/grub/grubenv set "next_entry=$2"
  truncate -s 256M esp.img ; mkfs.vfat -F 32 -i $ESP_UUID esp.img >/dev/null
  mcopy -s -i esp.img esp/* ::/
  truncate -s 128M bootp.img ; mkfs.ext4 -q -U $BOOT_UUID -O ^metadata_csum_seed -d boot bootp.img
  truncate -s 400M disk.img
  printf 'label: gpt\nstart=2048, size=524288, type=C12A7328-F81F-11D2-BA4B-00A0C91EC93B\nstart=526336, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' | sfdisk -q disk.img
  dd if=esp.img of=disk.img bs=512 seek=2048 conv=notrunc status=none
  dd if=bootp.img of=disk.img bs=512 seek=526336 conv=notrunc status=none
}
grubenv() { dd if=disk.img of=bp.img bs=512 skip=526336 count=262144 status=none; debugfs -R 'cat /grub/grubenv' bp.img 2>/dev/null | grep -a '='; }
boot() { # log
  cp "$OVMF_VARS" vars.fd ; chmod u+w vars.fd
  timeout 120 qemu-system-x86_64 -machine q35,accel=kvm -m 1024 -no-reboot -display none -monitor none \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file=vars.fd \
    -drive file=disk.img,if=virtio,format=raw -serial file:"$1" || true
  tr -d '\r' < "$1" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' > "$1.txt"
}
pass=1
check() { if grep -q "$2" "$1.txt"; then echo "[PASS] $3"; else echo "[FAIL] $3"; pass=0; fi; }

echo "== A: one-time NixOS, systemd-boot present"
mkdisk yes nixos ; boot A.log
check A.log 'FAKE-DEBIAN-BOOTED' 'GRUB chainloaded systemd-boot, which booted the UKI'
echo "   grubenv after: $(grubenv | tr '\n' ' ')"
grubenv | grep -qx 'next_entry=' && echo "[PASS] next_entry cleared" || { echo "[FAIL] next_entry not cleared"; pass=0; }

echo "== B: one-time NixOS, systemd-boot missing"
mkdisk no nixos ; boot B.log
check B.log 'rebooting into Debian' 'failed chainload printed the message and rebooted'
if grep -q DEBIAN-ENTRY-CHOSEN B.log.txt; then echo "[FAIL] Debian ran in the same boot"; pass=0; fi
echo "   grubenv after: $(grubenv | tr '\n' ' ')"
grubenv | grep -qx 'next_entry=' && echo "[PASS] next_entry cleared" || { echo "[FAIL] next_entry not cleared"; pass=0; }

echo "== C: the boot after B"
boot C.log
check C.log 'DEBIAN-ENTRY-CHOSEN' 'next boot is Debian'

echo "== logs in $W"
[ $pass = 1 ] && echo "ALL PASS" || echo "SOME FAILED"
