{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, glibc
, zlib
}:

stdenv.mkDerivation {
  pname = "antigravity-cli";
  version = "1.1.27";

  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.1.27-5211191891591168/linux-arm/cli_linux_arm64.tar.gz";
    hash = "sha512-7UX2kweFqktC8U4HrOHJ2RqU+3bnYPVKy9fT05UeH5V/1Fag2uKjEk3Zo7aJv3r7fJMDo+S6lQN/wQBjQk2b+Q==";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ glibc zlib ];

  dontUnpack = true;

  installPhase = ''
    tar -xzf "$src" -C "$TMPDIR"
    install -Dm755 "$TMPDIR/antigravity" "$out/bin/agy"
  '';

  meta = {
    description = "Google Antigravity agent-first coding CLI";
    homepage = "https://antigravity.google/docs/cli";
    license = lib.licenses.unfree;
    mainProgram = "agy";
    platforms = [ "aarch64-linux" ];
  };
}
