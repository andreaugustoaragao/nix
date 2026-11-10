{
  lib,
  writeShellApplication,
  runCommand,
  python3,
  noctalia,
  niri,
  glib,
}:
let
  python = python3.withPackages (ps: [ ps.pillow ]);
  script = ../home/desktop/gruvbox-trial.py;
  wallpapers = runCommand "gruvbox-trial-wallpapers" { } ''
    ${lib.getExe python} ${script} render \
      --source ${../assets/wallpapers} --wallpapers "$out"
  '';
in
writeShellApplication {
  name = "gruvbox-trial";
  runtimeInputs = [
    noctalia
    niri
    glib
  ];
  text = ''
    exec ${lib.getExe python3} ${script} --wallpapers ${wallpapers} "$@"
  '';
}
