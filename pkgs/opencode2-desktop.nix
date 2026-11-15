{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  gdk-pixbuf,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  systemd,
  vulkan-loader,
  wayland,
  xdg-utils,
}:

let
  version = "2.0.18";
  sources = {
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-mrbOXNX+LsQXQeNi2fDCwGsOMsyX5YVF4TwQLW4W9nk=";
    };
    x86_64-linux = {
      arch = "amd64";
      hash = "sha256-T3YFt2InG0q/YeizAfWd3zZm9KzvOIbq0yOjtd41ylA=";
    };
  };
  source = sources.${stdenv.hostPlatform.system};
  runtimeLibs = [
    fontconfig
    libdrm
    libgbm
    libGL
    libnotify
    libpulseaudio
    libsecret
    (lib.getLib systemd)
    vulkan-loader
    wayland
  ];
in
stdenv.mkDerivation {
  pname = "opencode2-desktop";
  inherit version;

  src = fetchurl {
    url = "https://opencode.ai/files/bin/${version}/opencode-desktop-linux-${source.arch}.deb";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gsettings-desktop-schemas
    gtk3
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    pango
    stdenv.cc.cc.lib
  ]
  ++ runtimeLibs;

  runtimeDependencies = runtimeLibs;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/opt" "$out/share"
    mv opt/OpenCode "$out/opt/OpenCode"
    cp -r usr/share/icons usr/share/applications "$out/share/"
    substituteInPlace "$out/share/applications/opencode-desktop.desktop" \
      --replace-fail 'Exec=/opt/OpenCode/ai.opencode.desktop %U' "Exec=$out/bin/opencode2-desktop %U"
    substituteInPlace "$out/share/applications/ai.opencode.desktop.desktop" \
      --replace-fail 'Exec=/opt/OpenCode/ai.opencode.desktop %U' "Exec=$out/bin/opencode2-desktop %U"

    runHook postInstall
  '';

  preFixup = ''
    makeWrapper "$out/opt/OpenCode/ai.opencode.desktop" "$out/bin/opencode2-desktop" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --set OPENCODE_DISABLE_AUTOUPDATE true \
      --add-flags --ozone-platform-hint=auto
  '';

  meta = {
    description = "OpenCode V2 desktop application";
    homepage = "https://opencode.ai/v2/";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "opencode2-desktop";
  };
}
