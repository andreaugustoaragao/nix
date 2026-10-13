{
  pkgs,
  unstable-pkgs,
  ...
}:
let
  layoutSync = pkgs.writeScriptBin "prl-display-layout" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./parallels-display-layout.py}
  '';
in
{
  systemd.user.services.prl-display-layout = {
    Unit = {
      Description = "Place Niri outputs using the Parallels host display layout";
      After = [ "niri-graphical-session.service" ];
      PartOf = [ "niri-graphical-session.service" ];
    };
    Service = {
      Environment = [
        "NIRI_BIN=${unstable-pkgs.niri}/bin/niri"
        "TAIL_BIN=${pkgs.coreutils}/bin/tail"
      ];
      ExecStart = "${layoutSync}/bin/prl-display-layout";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "niri-graphical-session.service" ];
  };
}
