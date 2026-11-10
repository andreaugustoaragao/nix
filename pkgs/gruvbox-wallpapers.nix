{
  lib,
  runCommand,
  python3,
}:
let
  python = python3.withPackages (ps: [ ps.pillow ]);
in
runCommand "gruvbox-wallpapers" { } ''
  ${lib.getExe python} ${../home/appearance/wallpapers.py} ${../assets/wallpapers} "$out"
''
