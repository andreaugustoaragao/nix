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
  version = "1.4.243";
  sources = {
    aarch64-linux = {
      debArch = "arm64";
      nodeArch = "arm64";
      hash = "sha256-ic1b7x5T3K0SlsLXprELedOP8Jac2acvBuf4KxYMxow=";
    };
    x86_64-linux = {
      debArch = "amd64";
      nodeArch = "x64";
      hash = "sha256-nwptDQqD6qELlDIYZHLdmOZJe07N0T1Sc5qzHPMM46U=";
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
  pname = "orca-ide";
  inherit version;

  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/orca-ide_${version}_${source.debArch}.deb";
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
  # ANGLE loads native EGL from a shared library with its own RUNPATH.
  appendRunpaths = [ "${lib.getLib libGL}/lib" ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;
  dontWrapGApps = true;
  dontAutoPatchelf = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/opt" "$out/share"
    mv opt/Orca "$out/opt/Orca"
    cp -r usr/share/icons usr/share/applications "$out/share/"
    patchShebangs "$out/opt/Orca/resources/bin/orca-ide"
    substituteInPlace "$out/share/applications/orca-ide.desktop" \
      --replace-fail 'Exec=/opt/Orca/orca-ide %U' "Exec=$out/bin/orca-desktop %U"

    runHook postInstall
  '';

  preFixup = ''
    makeWrapper "$out/opt/Orca/orca-ide" "$out/bin/orca-desktop" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --add-flags --ozone-platform-hint=auto
    makeWrapper "$out/opt/Orca/resources/bin/orca-ide" "$out/bin/orca-ide" \
      "''${gappsWrapperArgs[@]}"
  '';

  # Remote deployment templates must retain their original, portable binaries.
  postFixup = ''
    autoPatchelf --no-recurse "$out/opt/Orca" "$out/opt/Orca/resources"
    autoPatchelf \
      "$out/opt/Orca/resources/app.asar.unpacked" \
      "$out/opt/Orca/resources/node_modules" \
      "$out/opt/Orca/resources/bin" \
      "$out/opt/Orca/resources/ripgrep/linux-${source.nodeArch}"
  '';

  meta = {
    description = "Orca workspace for parallel AI coding agents";
    homepage = "https://www.onorca.dev/";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "orca-desktop";
  };
}
