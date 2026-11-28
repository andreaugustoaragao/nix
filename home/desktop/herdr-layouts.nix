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
  workIntakePkg = config.my.vaultV2.workIntakePackage or null;
  hasWorkIntake = workIntakePkg != null;
  intakeMain =
    if hasWorkIntake then
      pkgs.replaceVars "${workIntakePkg}/share/work-intake/mod/main.js" {
        notesRoot = "${config.home.homeDirectory}/projects/work/notes/";
      }
    else
      null;
  stripIntakeBadgeJq =
    ''walk(if type == "array" then [.[] | select(.id? != "work-intake-badge")] else . end)'';
  customRoot = pkgs.runCommand "herdr-custom" {
    nativeBuildInputs = [ pkgs.jq ];
  } ''
    cp -r ${customSource} "$out"
    chmod -R u+w "$out"
    ${
      lib.optionalString hasWorkIntake ''
        mkdir -p "$out/mods/work-intake"
        cp ${intakeMain} "$out/mods/work-intake/main.js"
        cp -a ${workIntakePkg}/share/work-intake/mod/model.js "$out/mods/work-intake/"
        cp -a ${workIntakePkg}/share/work-intake/mod/mod.json "$out/mods/work-intake/" 2>/dev/null || true
        cp -a ${workIntakePkg}/share/work-intake/mod/jsconfig.json "$out/mods/work-intake/" 2>/dev/null || true
        cp -a ${workIntakePkg}/share/work-intake/mod/gpui-kit.d.ts "$out/mods/work-intake/" 2>/dev/null || true
      ''
    }
    ${
      lib.optionalString (!hasWorkIntake) ''
        for layout in main-flat main-preview; do
          jq '${stripIntakeBadgeJq}' "$out/layouts/$layout.json" > "$out/layouts/$layout.json.tmp"
          mv "$out/layouts/$layout.json.tmp" "$out/layouts/$layout.json"
        done
      ''
    }
  '';
  intake =
    if hasWorkIntake then
      pkgs.writeShellApplication {
        name = "herdr-intake-dashboard";
        text = ''
          export HERDR_INTAKE_NOTES_ROOT=${lib.escapeShellArg "${config.home.homeDirectory}/projects/work/notes"}
          export HERDR_INTAKE_STATE_DIR=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/fulcrum-v2/work-intake"}
          exec ${lib.getExe' workIntakePkg "work-intake"} herdr-view "$@"
        '';
      }
    else
      null;
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
  syncedMods =
    [
      "auto-namer"
      "personal-costs"
      "preview"
    ]
    ++ lib.optionals hasWorkIntake [ "work-intake" ];
  customLayouts = [
    "main-flat"
    "main-preview"
  ];
in
{
  home.packages = lib.optionals hasWorkIntake [ intake workIntakePkg ];
  home.file.".local/bin/herdr-intake-dashboard" = lib.mkIf hasWorkIntake {
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
          --programs ${lib.escapeShellArg "${customRoot}/programs.json"} \
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