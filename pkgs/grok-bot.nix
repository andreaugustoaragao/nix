{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeShellWrapper,
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
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libGL,
  libglvnd,
  libnotify,
  libpulseaudio,
  libsecret,
  libuuid,
  libx11,
  libxcb,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxkbcommon,
  libxrandr,
  libxrender,
  libxscrnsaver,
  libxshmfence,
  libxtst,
  nspr,
  nss,
  pango,
  systemd,
  vulkan-loader,
  wayland,
  xdg-utils,
}:

let
  inherit (stdenv.hostPlatform) system;

  # Cursor stable feed: api2.cursor.sh/updates/api/update/linux-{x64,arm64}/sand/0.0.0/stable
  # The feed advertises an AppImage; the .deb lives at the same build id.
  # Prefetch both hashes with:
  #   nix store prefetch-file --hash-type sha256 "$url"
  downloadBase = "https://downloads.cursor.com/grokbot/stable";
  buildId = "c4074f405d36a56b406f11cc6485404ff8b395eb";
  version = "0.57.1";

  archTag = {
    x86_64-linux = "x64";
    aarch64-linux = "arm64";
  };
  debArch = {
    x86_64-linux = "amd64";
    aarch64-linux = "arm64";
  };
  hashes = {
    x86_64-linux = "sha256-ygNMwdslJuqHJ7ziMoGENAV8rKnloKc3chrQvypfS/M=";
    aarch64-linux = "sha256-0vNjzstKMtGv6GtuuvrH/kGxRZtlu2/yizvaiMMDcPY=";
  };

  # Chromium dlopen()s these at runtime, so autoPatchelfHook cannot see them.
  runtimeLibs = [
    libglvnd
    libGL
    libgbm
    libdrm
    vulkan-loader
    wayland
    libxkbcommon
    libpulseaudio
    libsecret
    libnotify
    (lib.getLib systemd)
  ];
in
stdenv.mkDerivation {
  pname = "grok-bot";
  inherit version;

  src = fetchurl {
    url = "${downloadBase}/${buildId}/linux/${archTag.${system}}/grok-bot_${version}_${debArch.${system}}.deb";
    hash = hashes.${system} or (throw "grok-bot: unsupported system ${system}");
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeShellWrapper
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
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libuuid
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    libx11
    libxcb
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxscrnsaver
    libxshmfence
    libxtst
  ]
  ++ runtimeLibs;

  runtimeDependencies = runtimeLibs;

  # Prebuilt Electron — stripping buys nothing and takes minutes.
  dontStrip = true;
  dontConfigure = true;
  dontBuild = true;

  # Wrap by hand so the GApps args land on our own wrapper.
  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/grok-bot"
    cp -r "opt/Grok Bot/." "$out/share/grok-bot/"

    # chrome-sandbox needs to be setuid root, which the Nix store cannot do.
    # Chromium falls back to the user-namespace sandbox (enabled on NixOS).
    rm -f "$out/share/grok-bot/chrome-sandbox"

    foundIcon=""
    for extension in png svg; do
      for icon in usr/share/icons/hicolor/*/apps/{sand,grok-bot}."$extension"; do
        [ -f "$icon" ] || continue
        relativeIcon="''${icon#usr/share/icons/hicolor/}"
        iconSize="''${relativeIcon%%/*}"
        install -Dm644 "$icon" \
          "$out/share/icons/hicolor/$iconSize/apps/grok-bot.$extension"
        foundIcon=1
      done
    done
    if [ -z "$foundIcon" ]; then
      echo "error: no grok-bot/sand hicolor icon found in the .deb" >&2
      exit 1
    fi

    if [ -f usr/share/applications/grok-bot.desktop ]; then
      desktop=usr/share/applications/grok-bot.desktop
    else
      desktop=usr/share/applications/sand.desktop
    fi
    install -Dm644 "$desktop" "$out/share/applications/grok-bot.desktop"

    if ! grep -q '^Exec=' "$out/share/applications/grok-bot.desktop"; then
      echo "error: upstream desktop file has no Exec entry" >&2
      exit 1
    fi
    sed -i \
      -e "s|^Exec=.*|Exec=$out/bin/grok-bot %U|" \
      -e 's/^Icon=.*/Icon=grok-bot/' \
      "$out/share/applications/grok-bot.desktop"

    runHook postInstall
  '';

  preFixup = ''
    # makeShellWrapper, not makeWrapper: wrapGAppsHook3 pulls in
    # makeBinaryWrapper, whose wrappers pass argv through literally. The
    # conditional ozone flags below need real shell parameter expansion.
    #
    # CHROME_DESKTOP is how Electron's setAsDefaultProtocolClient() decides
    # which .desktop id to hand xdg-settings when the app registers sand://.
    # Unset, it guesses "electron.desktop" and login redirects never land.
    #
    # --no-sandbox: upstream's Electron crash-loops sandboxed <webview>
    # renderers (FATAL:platform_shared_memory_region_posix.cc). Upstream
    # already launches the main renderer, GPU, and utilities unsandboxed;
    # the webview was the only sandboxed process and it only ever crashed.
    if [ -x "$out/share/grok-bot/grok-bot" ]; then
      upstreamExecutable="$out/share/grok-bot/grok-bot"
    else
      upstreamExecutable="$out/share/grok-bot/sand"
    fi

    makeShellWrapper "$upstreamExecutable" "$out/bin/grok-bot" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --set-default CHROME_DESKTOP grok-bot.desktop \
      --add-flags "--no-sandbox" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"

    ln -s "$out/bin/grok-bot" "$out/bin/sand"
  '';

  meta = {
    description = "Grok Bot desktop agent";
    homepage = "https://x.ai/bot";
    downloadPage = "https://x.ai/bot";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "grok-bot";
  };
}
