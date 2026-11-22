{
  config,
  lib,
  pkgs,
  isDarwinHost ? false,
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
  customSource = builtins.path {
    name = "herdr-custom";
    path = ./herdr;
  };
  intakeMain = pkgs.replaceVars ./herdr/mods/work-intake/main.js {
    notesRoot = "${config.home.homeDirectory}/projects/work/notes/";
  };
  customRoot = pkgs.runCommand "herdr-custom" { } ''
    cp -r ${customSource} "$out"
    chmod -R u+w "$out"
    cp ${intakeMain} "$out/mods/work-intake/main.js"
  '';
  intakeSource = builtins.path {
    name = "herdr-intake-viewer";
    path = ./herdr-intake;
  };
  intake = pkgs.writeShellApplication {
    name = "herdr-intake-dashboard";
    text = ''
      export HERDR_INTAKE_NOTES_ROOT=${lib.escapeShellArg "${config.home.homeDirectory}/projects/work/notes"}
      exec ${lib.getExe pkgs.python3} ${intakeSource}/dashboard.py "$@"
    '';
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
    "work"
    "work-intake"
  ];
  customLayouts = [
    "main-flat"
    "main-preview"
  ];
in
{
  home.packages = [ intake ];
  home.file.".local/bin/herdr-intake-dashboard" = {
    source = lib.getExe intake;
    force = true;
  };
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
        source = "${customSource}/layouts/${name}.json";
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

  home.activation.herdrDefaultLayout =
    lib.hm.dag.entryAfter
      [
        "linkGeneration"
        "herdrSyncedMods"
      ]
      ''
          run ${lib.getExe pkgs.python3} ${./herdr-configure.py} \
            --root ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app"} \
            --layout main-flat \
        --app ${
          if isDarwinHost then "herdr-app" else lib.getExe (pkgs.callPackage ../../pkgs/herdr-app.nix { })
        }
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
      if [ -L "$dst" ]; then
        rm -- "$dst"
      fi
      mkdir -p "$dst"
      # Replace any old store symlinks or backups with writable copies from Nix.
      find "$dst" -maxdepth 4 \( -name '*.hm-backup' -o -type l ! -name 'node_modules' \) -delete
      cp -rf --no-preserve=mode "$src"/. "$dst"/
    '') syncedMods
    + ''
      opencodePreviewDir=${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/mods/preview/integrations/opencode"}
      if [ -e "$opencodePreviewDir/tui.js" ] || [ -L "$opencodePreviewDir/tui.js" ]; then
        run ${pkgs.coreutils}/bin/rm -f -- "$opencodePreviewDir/tui.js"
      fi
      if [ -d "$opencodePreviewDir" ]; then
        run ${pkgs.coreutils}/bin/rmdir --ignore-fail-on-non-empty -- "$opencodePreviewDir"
      fi
    ''
  );
}
