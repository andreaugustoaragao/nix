{
  lib,
  callPackage,
  makeRustPlatform,
  makeWrapper,
  runCommand,
  python3,
  writeText,
  fuzzel,
  niri,
  hyprland,
  stdenv,
}:
let
  rustToolchain = callPackage ./rust-toolchain.nix { };
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
  importCargoLockStatic = callPackage ../overlays/import-cargo-lock.nix {
    cargo = rustToolchain;
  };
  profiles = writeText "browser-profiles.json" (builtins.toJSON (import ./browser-profiles.nix));
  desktopArgs = lib.optionals stdenv.hostPlatform.isLinux [
    "--niri"
    (lib.getExe niri)
    "--hyprctl"
    "${hyprland}/bin/hyprctl"
    "--fuzzel"
    (lib.getExe fuzzel)
  ];
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "browser-task";
  version = "0.1.0";
  src = builtins.path {
    name = "browser-task-source";
    path = ./browser-task;
    filter = path: type: !(type == "directory" && builtins.baseNameOf path == "target");
  };
  cargoDeps = importCargoLockStatic {
    lockFile = ./browser-task/Cargo.lock;
  };
  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram "$out/bin/browser-task" \
      --add-flags ${
        lib.escapeShellArg (
          lib.escapeShellArgs (
            [
              "--config"
              profiles
            ]
            ++ desktopArgs
          )
        )
      }
  '';
  passthru.tests.protocol = runCommand "check-browser-task-protocol" { } ''
    PYTHONDONTWRITEBYTECODE=1 ${python3}/bin/python3 \
      ${./browser-task/tests/protocol.py} ${lib.getExe finalAttrs.finalPackage}
    touch "$out"
  '';
  passthru.tests.failure-modes = runCommand "check-browser-task-failure-modes" { } ''
    PYTHONDONTWRITEBYTECODE=1 ${python3}/bin/python3 \
      ${finalAttrs.src}/tests/failure_modes.py ${lib.getExe finalAttrs.finalPackage}
    touch "$out"
  '';
  meta = {
    description = "Task-owned browser automation over native Chrome DevTools Protocol";
    mainProgram = "browser-task";
    platforms = lib.platforms.unix;
  };
})
