{
  config,
  lib,
  pkgs,
  ...
}:
let
  package = pkgs.callPackage ../../pkgs/herdr-agent-preview.nix { };
in
{
  home.packages = [ package ];
  home.file.".pi/agent/extensions/herdr-preview.js" = {
    text = ''export { default } from "${package}/share/herdr-preview/integrations/pi.js";'';
    force = true;
  };
  home.activation.herdrPreviewAdoption = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    original=${lib.escapeShellArg "${config.home.homeDirectory}/.pi/agent/extensions/herdr-preview.js"}
    backup=${lib.escapeShellArg "${config.xdg.stateHome}/nix-agent-adoption/herdr-preview.js"}
    if [ -e "$original" ] && [ ! -L "$original" ] && [ ! -e "$backup" ]; then
      run ${pkgs.coreutils}/bin/install -d -m 0700 "$(dirname "$backup")"
      run ${pkgs.coreutils}/bin/cp -a -- "$original" "$backup"
    fi
  '';
}
