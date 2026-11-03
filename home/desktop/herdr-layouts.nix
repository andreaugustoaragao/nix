{ pkgs, ... }:

let
  layoutSource = pkgs.fetchFromGitHub {
    owner = "herdrdev";
    repo = "herdr-layout-examples";
    rev = "0ec967640bf854ffb839e9af06c1e0c328bc9815";
    hash = "sha256-vrA4BkUrIVQZrOFhfzCSTjQFygjldQx9pB80tOcudzI=";
  };
  layouts = pkgs.applyPatches {
    name = "herdr-layouts";
    src = layoutSource;
    patches = [ ./herdr-board-theme.patch ];
  };
in
{
  xdg.configFile = {
    "herdr-app/layouts/board.json".source = "${layouts}/board/layouts/board.json";
    "herdr-app/layouts/mission.json".source = "${layouts}/mission/layouts/mission.json";
    "herdr-app/mods/board" = {
      source = "${layouts}/board/mods/board";
      recursive = true;
    };
    "herdr-app/mods/mission" = {
      source = "${layouts}/mission/mods/mission";
      recursive = true;
    };
  };
}
