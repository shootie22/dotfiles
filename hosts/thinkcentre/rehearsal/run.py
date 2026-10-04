#!/usr/bin/env python3
"""Rehearsal of the thinkcentre's move to NixOS (infrastructure #18).

Boots the rehearsal disk image in QEMU with UEFI firmware (OVMF) and walks
through the failure scenarios the boot safety layers exist for. The VM is
driven over its serial console: it types the disk passphrase, logs in (root
autologin), runs efibootmgr the same way the real migration will, and watches
for "FAKE-DEBIAN-BOOTED", which the stand-in Debian prints before powering off.

Usage (on a machine with KVM, inside an empty work directory):
  nix build .#nixosConfigurations.thinkcentre-rehearsal.config.system.build.diskoImages
  nix shell nixpkgs#qemu_kvm nixpkgs#OVMF.fd -c python3 run.py --image <result>/nvme.qcow2 --ovmf <OVMF.fd path>

Everything it creates stays in the current directory.
"""

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import time

PASSPHRASE = "test"
# The prompt is colored: "...]#" followed by an escape sequence, not a space.
PROMPT = re.compile(rb"root@thinkcentre-rehearsal[^\r\n]*#")
MARKER = b"FAKE-DEBIAN-BOOTED"
ASK = re.compile(rb"passphrase for disk", re.I)


class VM:
    """One QEMU process with the serial console on a socket."""

    def __init__(self, name, disk, vars_fd, ovmf_code, network=True):
        self.name = name
        self.log = open(f"{name}.serial.log", "wb")
        self.buf = b""
        self.sock_path = f"{name}.serial.sock"
        self.mon_path = f"{name}.monitor.sock"
        for p in (self.sock_path, self.mon_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = [
            "qemu-system-x86_64",
            "-machine", "q35,accel=kvm",
            "-cpu", "host",
            "-m", "2048",
            "-smp", "2",
            "-display", "none",
            "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
            "-drive", f"if=pflash,format=raw,file={vars_fd}",
            "-drive", f"file={disk},if=virtio,format=qcow2",
            "-netdev", "user,id=n0",
            "-device", "virtio-net-pci,netdev=n0,addr=0x3",
            # Let the emulated iTCO watchdog actually reset the machine.
            "-global", "ICH9-LPC.noreboot=false",
            "-chardev", f"socket,id=s0,path={self.sock_path},server=on,wait=on",
            "-serial", "chardev:s0",
            "-monitor", f"unix:{self.mon_path},server=on,wait=off",
        ]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(f"{name}.qemu.log", "wb"))
        for _ in range(100):
            if os.path.exists(self.sock_path):
                break
            time.sleep(0.1)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.sock_path)
        self.sock.settimeout(1)
        if not network:
            self.monitor("set_link n0 off")

    def monitor(self, command):
        for _ in range(50):
            try:
                m = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                m.connect(self.mon_path)
                m.sendall(command.encode() + b"\n")
                time.sleep(0.3)
                m.close()
                return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("no QEMU monitor")

    def _read(self):
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return True
        except OSError:
            return False
        if not data:
            return False
        self.log.write(data)
        self.log.flush()
        self.buf += data
        return True

    def expect(self, patterns, timeout):
        """Wait for the first of several patterns. Returns its index, or -1
        on timeout, or -2 when QEMU exited."""
        pats = [p if isinstance(p, re.Pattern) else re.compile(re.escape(p)) for p in patterns]
        deadline = time.time() + timeout
        while time.time() < deadline:
            for i, p in enumerate(pats):
                m = p.search(self.buf)
                if m:
                    self.buf = self.buf[m.end():]
                    return i
            if not self._read():
                return -2
        return -1

    def send(self, text):
        self.sock.sendall(text.encode())

    def run(self, command, timeout=60):
        """Run a shell command at the root prompt, return its output. The end
        tag is split with quotes so the echoed command line doesn't match."""
        n = time.time_ns()
        tag = f"__END_{n}__".encode()
        self.send(f'{command}; echo __END_""{n}__\n')
        deadline = time.time() + timeout
        while tag not in self.buf:
            if time.time() > deadline or not self._read():
                raise RuntimeError(f"command timed out: {command}")
        text, self.buf = self.buf.split(tag, 1)
        lines = text.decode(errors="replace").replace("\r", "").split("\n")
        # The output starts after the last echo of the command line (the
        # terminal can echo it more than once, with prompt and escape codes).
        echo = f'__END_""{n}__'
        last = max((i for i, l in enumerate(lines) if echo in l), default=0)
        out = "\n".join(lines[last + 1:])
        return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07", "", out).strip()

    def unlock_and_login(self, timeout=300):
        i = self.expect([ASK, MARKER], timeout)
        if i != 0:
            return {1: "landed in fake Debian instead", -1: "no passphrase prompt", -2: "QEMU exited"}[i]
        time.sleep(0.5)
        self.send(PASSPHRASE + "\n")
        if self.expect([PROMPT], timeout) != 0:
            return "no root prompt after unlocking"
        time.sleep(2)
        self.send("\n")
        self.expect([PROMPT], 10)
        return None

    def wait_exit(self, timeout):
        # Keep draining the console: a full serial buffer blocks the guest,
        # shutdown included.
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                return True
            self._read()
        return self.proc.poll() is not None

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        self.log.close()
        for p in (self.sock_path, self.mon_path):
            if os.path.exists(p):
                os.unlink(p)


def boot_entries(vm):
    """Numbers of the 'debian' and 'nixos' firmware entries."""
    out = vm.run("efibootmgr")
    nums = {}
    for line in out.splitlines():
        m = re.match(r"Boot([0-9A-F]{4})\*? (debian|nixos)\b", line)
        if m:
            nums[m.group(2)] = m.group(1)
    return nums, out


class Rehearsal:
    def __init__(self, args):
        self.args = args
        self.ovmf_code = os.path.join(args.ovmf, "FV", "OVMF_CODE.fd")
        self.results = []

    def disk(self, name, base):
        path = f"{name}.qcow2"
        subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", os.path.abspath(base), path], check=True)
        return path

    def vars_copy(self, name, src):
        dst = f"{name}.vars.fd"
        shutil.copy(src, dst)
        os.chmod(dst, 0o644)
        return dst

    def record(self, scenario, ok, detail):
        self.results.append((scenario, ok, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {scenario}: {detail}", flush=True)

    # Setup ------------------------------------------------------------------
    def setup(self):
        """First boot from the firmware's fallback path (systemd-boot), then
        create the firmware entries like the real migration does. Produces:
          base.qcow2           disk after setup, NixOS entry not yet blessed
          vars-debian-first    Debian first in BootOrder
          vars-trial           Debian first, BootNext = NixOS
          vars-nixos-first     NixOS first (firmware ignoring the order)
        """
        shutil.copy(self.args.image, "base.qcow2")
        os.chmod("base.qcow2", 0o644)
        blank = os.path.join(self.args.ovmf, "FV", "OVMF_VARS.fd")

        # Every setup boot has to come up in NixOS, so the later ones start
        # from the NixOS-first state and only change the order at the end.
        steps = [
            ("vars-nixos-first", blank, "nixos-first"),
            ("vars-debian-first", "vars-nixos-first.fd", "debian-first"),
            ("vars-trial", "vars-nixos-first.fd", "trial"),
        ]
        for name, src, mode in steps:
            vars_fd = self.vars_copy(f"setup-{mode}", src)
            vm = VM(f"setup-{mode}", "base.qcow2", vars_fd, self.ovmf_code)
            try:
                err = vm.unlock_and_login()
                if err:
                    raise RuntimeError(f"setup ({mode}): {err}")
                nums, _ = boot_entries(vm)
                if "debian" not in nums:
                    vm.run("efibootmgr -C -d /dev/vda -p 1 -L debian -l '\\EFI\\debian\\shimx64.efi'")
                if "nixos" not in nums:
                    vm.run("efibootmgr -C -d /dev/vda -p 1 -L nixos -l '\\EFI\\systemd\\systemd-bootx64.efi'")
                nums, out = boot_entries(vm)
                others = [m for m in re.findall(r"BootOrder: ([0-9A-F,]+)", out)[0].split(",") if m not in nums.values()] if "BootOrder" in out else []
                if mode == "nixos-first":
                    order = [nums["nixos"], nums["debian"]] + others
                else:
                    order = [nums["debian"], nums["nixos"]] + others
                vm.run(f"efibootmgr -o {','.join(order)}")
                if mode == "trial":
                    vm.run(f"efibootmgr -n {nums['nixos']}")
                # Undo the blessing of this boot, so the scenarios start with a
                # fresh boot counter like a just-installed generation.
                vm.run("cd /boot/loader/entries && for f in nixos-*.conf; do case $f in nixos-zz-*) continue ;; esac; "
                       "b=${f%.conf}; b=${b%%+*}; [ \"$f\" = \"$b+3.conf\" ] || mv \"$f\" \"$b+3.conf\"; done; ls; sync")
                print(f"setup {mode}: {vm.run('efibootmgr | head -4')}".replace("\n", " | "), flush=True)
                vm.send("poweroff\n")
                if not vm.wait_exit(120):
                    raise RuntimeError(f"setup ({mode}): no poweroff")
            finally:
                vm.close()
            shutil.copy(vars_fd, f"{name}.fd")
        self.entries = nums

    # Scenarios --------------------------------------------------------------
    def scenario_trial_boot(self):
        """BootNext starts NixOS once; the next reboot is Debian again."""
        s = "trial boot: BootNext starts NixOS once, then Debian again"
        vm = VM("s1", self.disk("s1", "base.qcow2"), self.vars_copy("s1", "vars-trial.fd"), self.ovmf_code)
        try:
            err = vm.unlock_and_login()
            if err:
                return self.record(s, False, err)
            out = vm.run("efibootmgr | head -3")
            current_ok = f"BootCurrent: {self.entries['nixos']}" in out and "BootNext" not in out
            vm.run("for i in $(seq 60); do systemctl is-active -q systemd-bless-boot && break; sleep 2; done", timeout=150)
            entries = vm.run("ls /boot/loader/entries")
            # A blessed entry has no "+tries" counter left in its name.
            blessed = re.search(r"nixos-[0-9a-f]{16,}\.conf", entries) is not None
            sshd = vm.run("systemctl is-active sshd")
            health = vm.run("systemctl is-active boot-health")
            k3s = vm.run("systemctl is-active fake-k3s")
            vm.send("reboot\n")
            back_to_debian = vm.expect([MARKER, ASK], 180) == 0
            ok = current_ok and blessed and back_to_debian
            self.record(s, ok, f"BootCurrent=nixos and BootNext consumed: {current_ok}; boot blessed: {blessed} "
                               f"({entries.split()}); next reboot in Debian: {back_to_debian}")
            self.record("missing data disk: boot completes, sshd up, k3s stand-in waits",
                        sshd == "active" and health == "active" and k3s != "active",
                        f"sshd {sshd}, boot-health {health}, k3s stand-in {k3s}")
        finally:
            vm.close()

    def scenario_no_unlock_trial(self):
        s = "trial boot, nobody unlocks: back in Debian after the timeout"
        vm = VM("s2", self.disk("s2", "base.qcow2"), self.vars_copy("s2", "vars-trial.fd"), self.ovmf_code)
        try:
            if vm.expect([ASK, MARKER], 300) != 0:
                return self.record(s, False, "no passphrase prompt")
            t0 = time.time()
            got = vm.expect([MARKER], 600)
            self.record(s, got == 0, f"fake Debian after {time.time() - t0:.0f} s (timeout 2 min)" if got == 0 else "never reached Debian")
        finally:
            vm.close()

    def scenario_firmware_ignores_order_no_unlock(self):
        s = "firmware always boots NixOS, nobody unlocks: Debian after 3 tries"
        vm = VM("s3", self.disk("s3", "base.qcow2"), self.vars_copy("s3", "vars-nixos-first.fd"), self.ovmf_code)
        try:
            tries = 0
            t0 = time.time()
            while True:
                i = vm.expect([ASK, MARKER], 600)
                if i == 1:
                    break
                if i != 0:
                    return self.record(s, False, f"stuck after {tries} tries")
                tries += 1
                if tries > 5:
                    return self.record(s, False, "more than 5 tries, boot counting not falling back")
            self.record(s, tries == 3, f"fake Debian after {tries} unlock prompts, {time.time() - t0:.0f} s")
        finally:
            vm.close()

    def scenario_no_network(self):
        s = "NixOS boots but has no network: Debian after 3 tries"
        vm = VM("s4", self.disk("s4", "base.qcow2"), self.vars_copy("s4", "vars-nixos-first.fd"), self.ovmf_code, network=False)
        try:
            boots = 0
            t0 = time.time()
            while True:
                i = vm.expect([ASK, MARKER], 900)
                if i == 1:
                    break
                if i != 0:
                    return self.record(s, False, f"stuck after {boots} boots")
                boots += 1
                if boots > 5:
                    return self.record(s, False, "more than 5 boots")
                time.sleep(0.5)
                vm.send(PASSPHRASE + "\n")
            self.record(s, boots == 3, f"fake Debian after {boots} unlocked boots without LAN, {time.time() - t0:.0f} s")
        finally:
            vm.close()

    def scenario_panic(self):
        s = "kernel panic: automatic reboot"
        vm = VM("s5", self.disk("s5", "base.qcow2"), self.vars_copy("s5", "vars-trial.fd"), self.ovmf_code)
        try:
            err = vm.unlock_and_login()
            if err:
                return self.record(s, False, err)
            vm.send("echo c > /proc/sysrq-trigger\n")
            t0 = time.time()
            got = vm.expect([MARKER, ASK], 120)
            self.record(s, got == 0, f"rebooted into Debian {time.time() - t0:.0f} s after the panic" if got == 0 else "no reboot")
        finally:
            vm.close()

    def scenario_watchdog(self):
        s = "hardware watchdog armed"
        vm = VM("s6", self.disk("s6", "base.qcow2"), self.vars_copy("s6", "vars-trial.fd"), self.ovmf_code)
        try:
            err = vm.unlock_and_login()
            if err:
                return self.record(s, False, err)
            out = vm.run("cat /sys/class/watchdog/watchdog0/identity /sys/class/watchdog/watchdog0/state /sys/class/watchdog/watchdog0/timeout 2>&1")
            self.record(s, "active" in out, out.replace("\n", " "))
        finally:
            vm.close()

    def scenario_bad_update(self):
        s = "after the trial, a broken generation: back to the previous NixOS"
        vm = VM("s7", self.disk("s7", "base.qcow2"), self.vars_copy("s7", "vars-nixos-first.fd"), self.ovmf_code)
        try:
            err = vm.unlock_and_login()
            if err:
                return self.record(s, False, err)
            vm.run("for i in $(seq 60); do systemctl is-active -q systemd-bless-boot && break; sleep 2; done")
            good = vm.run("readlink -f /run/current-system")
            vm.run("deploy-broken", timeout=300)
            vm.send("reboot\n")
            boots = 0
            while True:
                i = vm.expect([ASK, MARKER], 900)
                if i != 0:
                    return self.record(s, False, "landed in Debian, not the previous NixOS" if i == 1 else f"stuck after {boots} boots")
                boots += 1
                time.sleep(0.5)
                vm.send(PASSPHRASE + "\n")
                if vm.expect([PROMPT], 300) != 0:
                    return self.record(s, False, "no prompt")
                time.sleep(2)
                vm.send("\n")
                vm.expect([PROMPT], 10)
                cur = vm.run("readlink -f /run/current-system")
                if cur == good:
                    break
                if boots > 5:
                    return self.record(s, False, "never fell back")
                # The broken generation reboots itself once its health check gives up.
            self.record(s, boots == 4, f"previous generation running after {boots} boots (3 failed, then the good one)")
        finally:
            vm.close()

    def main(self):
        os.chdir(self.args.workdir)
        self.setup()
        for sc in (self.scenario_trial_boot, self.scenario_no_unlock_trial, self.scenario_firmware_ignores_order_no_unlock,
                   self.scenario_no_network, self.scenario_panic, self.scenario_watchdog, self.scenario_bad_update):
            if self.args.only and sc.__name__ not in self.args.only:
                continue
            try:
                sc()
            except Exception as e:  # keep going with the next scenario
                self.record(sc.__name__, False, f"error: {e}")
        print("\n== summary")
        for s, ok, d in self.results:
            print(f"{'PASS' if ok else 'FAIL'}  {s}")
        return 0 if all(ok for _, ok, _ in self.results) else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--ovmf", required=True, help="path of the OVMF.fd package (with FV/)")
    ap.add_argument("--workdir", default=".")
    ap.add_argument("--only", nargs="*")
    sys.exit(Rehearsal(ap.parse_args()).main())
