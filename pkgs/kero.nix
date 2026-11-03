{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  cairo,
  fontconfig,
  gdk-pixbuf,
  glib,
  gtk3,
  gtk-layer-shell,
  harfbuzz,
  libayatana-appindicator,
  libepoxy,
  libGL,
  libsecret,
  libx11,
  libxkbcommon,
  libsoup_3,
  pango,
  wayland,
  webkitgtk_4_1,
  xdg-utils,
}:

let
  version = "2.1.31";
  sources = {
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-8y9mU1CBL+tCfzN3eN9sVpVTXROBpaU7jnWTlN85HNs=";
    };
    x86_64-linux = {
      arch = "amd64";
      hash = "sha256-peiEdxTdTeYBNEV0JWe7QUJt9G2pE5MRxdRcCWuDUhE=";
    };
  };
  source = sources.${stdenv.hostPlatform.system};
  runtimeLibs = [
    cairo
    fontconfig
    gdk-pixbuf
    glib
    gtk3
    gtk-layer-shell
    harfbuzz
    libayatana-appindicator
    libepoxy
    libGL
    libsecret
    libx11
    libxkbcommon
    libsoup_3
    pango
    wayland
    webkitgtk_4_1
  ];
in
stdenv.mkDerivation {
  pname = "kero";
  inherit version;

  src = fetchurl {
    url = "https://github.com/egoist/kero/releases/download/v${version}/kero-${version}-linux-${source.arch}.tar.gz";
    inherit (source) hash;
  };
  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];
  buildInputs = runtimeLibs;

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 kero "$out/bin/kero"
    install -Dm755 libghostty-vt.so "$out/bin/libghostty-vt.so"
    cp -r fonts "$out/bin/fonts"
    install -Dm644 kero.desktop "$out/share/applications/kero.desktop"
    install -Dm644 kero.png "$out/share/icons/hicolor/1024x1024/apps/kero.png"
    runHook postInstall
  '';

  preFixup = ''
    wrapProgram "$out/bin/kero" \
      "''${gappsWrapperArgs[@]}" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs} \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]}
  '';

  meta = {
    description = "Terminal for coding agents";
    homepage = "https://github.com/egoist/kero";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "kero";
  };
}
