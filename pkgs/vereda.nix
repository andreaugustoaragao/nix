{
  lib,
  callPackage,
  rustPlatform,
  pkg-config,
  makeWrapper,
  glib,
  cairo,
  pango,
  gdk-pixbuf,
  fontconfig,
  gvfs,
  wayland,
  libxkbcommon,
  vulkan-loader,
  libGL,
  libglvnd,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  xdg-utils,
  poppler-utils,
  gdb,
  _7zz,
  zstd,
  exiftool,
  veredaSource ? null,
  zig ? null,
}:
if veredaSource == null then
  callPackage ./desktop-release.nix { pname = "vereda"; }
else
  let
    runeSource = callPackage "${veredaSource}/nix/rune-source.nix" { };
    version = (builtins.fromTOML (builtins.readFile "${veredaSource}/Cargo.toml")).package.version;
    libraries = [
      glib
      cairo
      pango
      gdk-pixbuf
      wayland
      libxkbcommon
      vulkan-loader
      libGL
      libglvnd
      libx11
      libxcursor
      libxi
      libxrandr
    ];
  in
  rustPlatform.buildRustPackage {
    pname = "vereda";
    inherit version;
    src = veredaSource;
    cargoLock.lockFile = "${veredaSource}/Cargo.lock";
    postPatch = ''
      ln -s ${runeSource} .rune-source
    '';
    dontUseZigConfigure = true;
    dontUseZigBuild = true;
    dontUseZigCheck = true;
    dontUseZigInstall = true;
    nativeBuildInputs = [
      pkg-config
      makeWrapper
      zig
      rustPlatform.bindgenHook
    ];
    buildInputs = libraries;
    doCheck = false;
    env.CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
    postInstall = ''
      cp -r share "$out/share"
      install -Dm644 -t "$out/share/licenses/vereda" LICENSE THIRD_PARTY_NOTICES.md
      for file in \
        share/applications/io.github.andrearagao.vereda.desktop \
        share/dbus-1/services/org.freedesktop.FileManager1.service \
        share/dbus-1/services/org.freedesktop.impl.portal.desktop.vereda.service \
        share/systemd/user/xdg-desktop-portal-vereda.service; do
        substituteInPlace "$out/$file" --replace-fail '@out@' "$out"
      done
      wrapProgram "$out/bin/vereda" \
        --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib:${lib.makeLibraryPath libraries}" \
        --set-default RUNE_GPU_LOG 0 \
        --prefix GIO_EXTRA_MODULES : "${gvfs}/lib/gio/modules" \
        --prefix PATH : "${
          lib.makeBinPath [
            glib
            fontconfig
            xdg-utils
            poppler-utils
            gdb
            _7zz
            zstd
            exiftool
          ]
        }"
    '';
    passthru.sourceRevision = veredaSource.rev or null;
    meta = {
      description = "Native Linux file manager, navigator, and previewer";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      mainProgram = "vereda";
    };
  }
