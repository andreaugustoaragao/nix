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
  libusb1,
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
  openssl,
  pango,
  qt5,
  qt6,
  systemd,
  tpm2-tss,
  vulkan-loader,
  wayland,
  xdg-utils,
}:

let
  version = "26.924.51851";
  sources = {
    aarch64-linux = {
      debArch = "arm64";
      nodeArch = "arm64";
      hash = "sha256-2l5GjF/OZEQRNMNR//v0OOOW7DrcanjDDpqk2/haMWg=";
    };
    x86_64-linux = {
      debArch = "amd64";
      nodeArch = "x64";
      hash = "sha256-fSW5n+ObA83D2DYx+yA9t3GGeIpTOHreDnBqJh6JaTU=";
    };
  };
  source = sources.${stdenv.hostPlatform.system};

  # Chromium and native modules load these dynamically.
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
  pname = "chatgpt-desktop";
  inherit version;

  src = fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${version}_${source.debArch}.deb";
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
    libusb1
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
    openssl
    pango
    (lib.getLib qt5.qtbase)
    (lib.getLib qt6.qtbase)
    stdenv.cc.cc.lib
    tpm2-tss
  ]
  ++ runtimeLibs;

  runtimeDependencies = runtimeLibs;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontWrapGApps = true;
  dontWrapQtApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib"
    mv usr/lib/chatgpt "$out/lib/chatgpt"

    # Node packages include foreign-platform and musl prebuilds. Keep only
    # native glibc variants so every installed ELF can be patched and loaded.
    while IFS= read -r -d "" prebuilds; do
      for target in "$prebuilds"/*; do
        case "''${target##*/}" in
          linux-${source.nodeArch}|HID-linux-${source.nodeArch}|HID_hidraw-linux-${source.nodeArch}) ;;
          *) rm -rf "$target" ;;
        esac
      done
    done < <(find "$out/lib/chatgpt/resources" -type d -name prebuilds -print0)
    find "$out/lib/chatgpt/resources" -name '*musl*.node' -delete

    install -Dm644 usr/share/pixmaps/chatgpt.png "$out/share/pixmaps/chatgpt.png"
    install -Dm644 usr/share/pixmaps/chatgpt.png \
      "$out/share/icons/hicolor/1024x1024/apps/chatgpt.png"
    install -Dm644 usr/share/applications/chatgpt.desktop \
      "$out/share/applications/chatgpt.desktop"
    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail 'Exec=chatgpt %U' "Exec=$out/bin/chatgpt %U" \
      --replace-fail 'MimeType=x-scheme-handler/codex;x-scheme-handler/http;x-scheme-handler/https;text/csv;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.openxmlformats-officedocument.presentationml.presentation;text/tab-separated-values;application/vnd.ms-excel;application/vnd.ms-excel.sheet.macroEnabled.12;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;' \
      'MimeType=x-scheme-handler/codex;'

    runHook postInstall
  '';

  # GApps populates its schema and module paths after the install phase.
  preFixup = ''
    makeWrapper "$out/lib/chatgpt/ChatGPT" "$out/bin/chatgpt" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --set-default CHROME_DESKTOP chatgpt.desktop
  '';

  meta = {
    description = "Official ChatGPT desktop app with Codex (Linux preview)";
    homepage = "https://learn.chatgpt.com/docs/linux/linux-app";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "chatgpt";
  };
}
