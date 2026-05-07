{
  lib,
  stdenv,
  kernel,
  makeWrapper,
  python3Packages,
}:

let
  python = python3Packages.python.withPackages (ps: [
    ps.configargparse
    ps.dbus-python
    ps.pyroute2
  ]);
in
stdenv.mkDerivation {
  pname = "xmm7360-pci";
  version = "unstable-2024-02-24";

  # The project has no releases. Keep this as fetchGit while we are testing the
  # modem, so the first rebuild can fetch the current experimental driver.
  src = builtins.fetchGit {
    url = "https://github.com/xmm7360/xmm7360-pci.git";
    ref = "master";
  };

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [
    makeWrapper
  ];

  postPatch = ''
    substituteInPlace Makefile \
      --replace-fail 'KVERSION := $(shell uname -r)' 'KVERSION := ${kernel.modDirVersion}' \
      --replace-fail 'KDIR := /lib/modules/$(KVERSION)/build' 'KDIR := ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build'

    # Linux 6.8 changed tty_operations.write to ssize_t (..., const u8 *, size_t).
    # Match flexibly because upstream formats this signature differently across
    # commits and forks.
    sed -i \
      -e 's/static int xmm7360_tty_write(struct tty_struct \*tty,/static ssize_t xmm7360_tty_write(struct tty_struct *tty,/' \
      -e 's/const unsigned char \*buffer, int count)/const u8 *buffer, size_t count)/' \
      xmm7360.c
    if grep -Eq 'static[[:space:]]+int[[:space:]]+xmm7360_tty_write[[:space:]]*\(' xmm7360.c; then
      echo "failed to patch xmm7360_tty_write for Linux 6.8+"
      exit 1
    fi

    substituteInPlace rpc/open_xdatachannel.py \
      --replace-fail 'logging.basicConfig(level=logging.DEBUG)' \
                     'logging.basicConfig(level=logging.INFO)'

    perl -0pi -e 's/if not cfg\.dbus:\n\s+sys\.exit\(1\)/if not cfg.dbus:\n    sys.exit(0)/s' rpc/open_xdatachannel.py
    if ! grep -A1 'if not cfg.dbus:' rpc/open_xdatachannel.py | grep -q 'sys.exit(0)'; then
      echo "failed to patch open_xdatachannel.py non-dbus exit"
      exit 1
    fi
  '';

  buildPhase = ''
    runHook preBuild
    make
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -D -m 0644 xmm7360.ko \
      "$out/lib/modules/${kernel.modDirVersion}/extra/xmm7360.ko"

    mkdir -p "$out/share/xmm7360-pci"
    cp -r rpc scripts examples trace "$out/share/xmm7360-pci/"
    install -m 0644 xmm7360.ini.sample "$out/share/xmm7360-pci/xmm7360.ini.sample"

    makeWrapper ${python}/bin/python "$out/bin/xmm7360-connect" \
      --add-flags "$out/share/xmm7360-pci/rpc/open_xdatachannel.py"

    runHook postInstall
  '';

  meta = {
    description = "Experimental PCI driver and connection tool for Intel XMM7360/Fibocom L850-GL";
    homepage = "https://github.com/xmm7360/xmm7360-pci";
    license = with lib.licenses; [ bsd3 gpl2Only ];
    platforms = lib.platforms.linux;
  };
}
