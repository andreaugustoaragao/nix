{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  wayland,
  libxkbcommon,
  vulkan-loader,
  libGL,
  libglvnd,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  glib,
  cairo,
  pango,
  gdk-pixbuf,
  fontconfig,
  gvfs,
  xdg-utils,
  poppler-utils,
  gdb,
  _7zz,
  exiftool,
  typst,
  python3Packages,
  pname,
}:
let
  release = (builtins.fromJSON (builtins.readFile ./desktop-releases.json)).${pname};
  inherit (release) version;
  system = stdenv.hostPlatform.system;
  libraries = [
    wayland
    libxkbcommon
    vulkan-loader
    libGL
    libglvnd
    libx11
    libxcursor
    libxi
    libxrandr
  ]
  ++ lib.optionals (pname == "vereda") [
    glib
    cairo
    pango
    gdk-pixbuf
  ];
in
stdenv.mkDerivation {
  inherit pname version;
  src = fetchurl {
    url = "https://github.com/andrearagao/desktop-releases/releases/download/${pname}-v${version}/${pname}-${version}-${system}.tar.gz";
    hash = release.hashes.${system};
  };
  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = libraries ++ [ stdenv.cc.cc.lib ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r bin share "$out/"
    mkdir -p "$out/share/${pname}"
    mv "$out/share/release.json" "$out/share/${pname}/release.json"
    mv "$out/share/licenses" "$out/share/${pname}/licenses"
    if [ -d libexec ]; then
      cp -r libexec "$out/"
    fi
  ''
  + lib.optionalString (pname == "vereda") ''
    for file in       share/applications/io.github.andrearagao.vereda.desktop       share/dbus-1/services/org.freedesktop.FileManager1.service       share/dbus-1/services/org.freedesktop.impl.portal.desktop.vereda.service       share/systemd/user/xdg-desktop-portal-vereda.service; do
      substituteInPlace "$out/$file" --replace-fail '@out@' "$out"
    done
  ''
  + ''
    runHook postInstall
  '';
  postFixup = ''
    wrapperArgs=(
      --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib:${lib.makeLibraryPath libraries}"
      --set-default RUNE_GPU_LOG 0
    )
    ${
      lib.optionalString (pname == "vereda") ''
        wrapperArgs+=(
          --prefix GIO_EXTRA_MODULES : "${gvfs}/lib/gio/modules"
          --prefix PATH : "${
            lib.makeBinPath [
              glib
              fontconfig
              xdg-utils
              poppler-utils
              gdb
              _7zz
              exiftool
            ]
          }"
        )
      ''
    }${
      lib.optionalString (pname == "folio") ''
        wrapperArgs+=(
          --prefix PATH : "${
            lib.makeBinPath [
              fontconfig
              xdg-utils
              typst
              python3Packages.weasyprint
            ]
          }"
        )
      ''
    }
    wrapProgram "$out/bin/${pname}" "''${wrapperArgs[@]}"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/${pname}" --help > /dev/null
    runHook postInstallCheck
  '';
  passthru.sourceRevision = release.sourceRevision;
  meta = {
    description =
      {
        folio = "Native Markdown reader";
        vereda = "Native Linux file manager, navigator, and previewer";
        vitals = "Native Linux system monitor";
      }
      .${pname};
    homepage = "https://github.com/andrearagao/desktop-releases";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames release.hashes;
    mainProgram = pname;
  };
}
