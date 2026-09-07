{ stdenvNoCC
, fetchurl
, autoPatchelfHook
, glibc
, openssl
, zlib
, stdenv
}:

stdenvNoCC.mkDerivation {
  pname = "komodo-periphery";
  version = "1.19.5";

  src = fetchurl {
    url = "https://github.com/moghtech/komodo/releases/download/v1.19.5/periphery-aarch64";
    sha256 = "04g15y4scsgqaf280270f0396p5326siqzf81mn5p6zhl86jhav8";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ glibc openssl zlib stdenv.cc.cc.lib ];

  dontUnpack = true;
  installPhase = ''
    install -Dm755 "$src" "$out/bin/periphery"
  '';
}
