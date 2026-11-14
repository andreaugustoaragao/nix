{
  config,
  lib,
  pkgs,
  ...
}:

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
  customRoot = builtins.path {
    name = "herdr-custom";
    path = ./herdr;
  };
  symlinkMods = [
    "personal-agents"
    "personal-chrome"
    "personal-pane"
    "personal-spaces"
    "personal-status"
    "preview-files"
    "preview-tabs"
  ];
  # Multi-file mods import sibling modules (e.g. ./rules.js, ./reader.js); herdr-app
  # requires resolved module paths to remain inside ~/.config/herdr-app/mods/<name>.
  syncedMods = [
    "auto-namer"
    "personal-costs"
    "preview"
  ];
  customLayouts = [
    "main-flat"
    "main-preview"
  ];
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
  }
  // builtins.listToAttrs (
    map (name: {
      name = "herdr-app/layouts/${name}.json";
      value = {
        source = "${customRoot}/layouts/${name}.json";
        force = true;
      };
    }) customLayouts
  )
  // builtins.listToAttrs (
    map (name: {
      name = "herdr-app/mods/${name}";
      value = {
        source = "${customRoot}/mods/${name}";
        recursive = true;
        force = true;
      };
    }) symlinkMods
  );

  home.activation.herdrDefaultLayout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    shared_file=${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/shared.json"}
    if [ ! -e "$shared_file" ]; then
      mkdir -p "$(dirname "$shared_file")"
      printf '{"layout":"main-flat"}\n' > "$shared_file"
    fi
  '';

  home.activation.herdrSyncedMods = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    ''
      keys_src=${lib.escapeShellArg "${customRoot}/keys.json"}
      keys_dst=${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/keys.json"}
      mkdir -p "$(dirname "$keys_dst")"
      if [ -L "$keys_dst" ] || ! cmp -s "$keys_src" "$keys_dst"; then
        rm -f "$keys_dst" "${config.xdg.configHome}/herdr-app/keys.json.hm-backup"
        cp -f --no-preserve=mode "$keys_src" "$keys_dst"
      fi
    ''
    + lib.concatMapStringsSep "\n" (name: ''
      src=${lib.escapeShellArg "${customRoot}/mods/${name}"}
      dst=${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/mods/${name}"}
      mkdir -p "$dst"
      # Replace any old store symlinks or backups with writable copies from Nix.
      find "$dst" -maxdepth 4 \( -name '*.hm-backup' -o -type l ! -name 'node_modules' \) -delete
      cp -rf --no-preserve=mode "$src"/. "$dst"/
    '') syncedMods
  );
}
