{
  lib,
  fetchurl,
  appimageTools,
}:

let
  pname = "thorium";
  version = "151.0.7922.72";

  # Upstream Alex313031/thorium releases stopped shipping binary assets once
  # gz83 took over maintenance; the actual AppImages are published on their
  # fork instead. AVX2 build picked since the target CPUs support it.
  src = fetchurl {
    url = "https://github.com/gz83/thorium/releases/download/M${version}/Thorium_Browser_${version}_AVX2.AppImage";
    hash = "sha256-/3Cf+Q/QhKW3PEaijfx1jFZl2OwLL5ylmFsHZYr8Tes=";
  };

  appimageContents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    install -m 444 -D ${appimageContents}/thorium-browser.desktop \
      $out/share/applications/thorium-browser.desktop
    install -m 444 -D ${appimageContents}/thorium-browser.png \
      $out/share/icons/hicolor/256x256/apps/thorium-browser.png
  '';

  meta = {
    description = "Chromium fork optimized for speed, with privacy patches and no Google integration";
    homepage = "https://github.com/Alex313031/thorium";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
    mainProgram = "thorium";
  };
}
