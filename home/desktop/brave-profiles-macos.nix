{
  config,
  pkgs,
  lib,
  ...
}:
# Reproducible Brave profile bring-up for macOS.
#
# Problem: Brave/Chromium's --profile-directory flag (used by the
# web-app .app bundles in web-apps-macos.nix) keys off the on-disk
# directory name, not the display name shown in the profile picker.
# Without a controlled seed, Brave auto-creates directories like
# Default/ and Profile 1/ whose display names ("Person 1", "Person 2")
# drift away from what the web-apps-data.nix entries reference.
#
# Solution: seed two directories named after the displayed profile so
# the on-disk name and the display name stay in lockstep —
#   Personal/  → profile.name = "Personal"
#   Work/      → profile.name = "Work"
# That makes `--profile-directory=Personal` and
# `--profile-directory=Work` resolve unambiguously.
#
# Workflow for a clean rebuild:
#   1. Quit Brave (Cmd+Q).
#   2. Run `brave-profiles-reset` — backs up the whole Brave-Browser
#      dir to a timestamped sibling, then removes Default/Personal/Work
#      and Local State.
#   3. `darwin-rebuild switch --flake ...` — activation reseeds the
#      Personal/ and Work/ skeletons.
#   4. Launch Brave; sign into each profile via brave://settings.
#
# After step 4 Brave owns these files. Activation is a no-op on every
# subsequent rebuild — it only seeds when a target file is missing.
let
  braveSupport = "${config.home.homeDirectory}/Library/Application Support/BraveSoftware/Brave-Browser";

  # Single source of truth. Directory name == display name == the
  # value passed as `profile = ...` in home/desktop/web-apps-data.nix.
  profileNames = [
    "Personal"
    "Work"
  ];

  # Minimal seed Preferences. Brave fills in every other field on first
  # launch and rewrites this file constantly thereafter; we only need
  # to pin profile.name so the picker doesn't relabel it to "Person N".
  seedPreferences =
    name:
    pkgs.writeText "brave-${name}-preferences.json" (
      builtins.toJSON {
        profile = {
          inherit name;
        };
      }
    );

  # Seed Local State registers both profiles in profile.info_cache so
  # Brave's picker shows them with the right display names on first
  # launch. is_using_default_name = false stops Brave from
  # auto-renaming. Brave will populate the missing fields itself.
  seedLocalState = pkgs.writeText "brave-local-state-seed.json" (
    builtins.toJSON {
      profile = {
        info_cache = lib.genAttrs profileNames (name: {
          inherit name;
          is_using_default_name = false;
        });
        # last_used picks which profile opens when Brave is launched
        # with no --profile-directory flag. Personal feels like the
        # safer default given the web-app split.
        last_used = "Personal";
      };
    }
  );

  resetScript = pkgs.writeShellScriptBin "brave-profiles-reset" ''
    set -euo pipefail
    BRAVE_DIR=${lib.escapeShellArg braveSupport}

    if pgrep -x "Brave Browser" >/dev/null 2>&1; then
      echo "Brave is running. Quit it (Cmd+Q) and re-run." >&2
      exit 1
    fi

    if [[ ! -d "$BRAVE_DIR" ]]; then
      echo "No Brave directory at $BRAVE_DIR — nothing to reset."
      exit 0
    fi

    BACKUP="$BRAVE_DIR.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up profile data to: $BACKUP"
    cp -R "$BRAVE_DIR" "$BACKUP"

    echo "Removing Default/, Personal/, Work/, Local State"
    rm -rf -- "$BRAVE_DIR/Default" "$BRAVE_DIR/Personal" "$BRAVE_DIR/Work"
    rm -f  -- "$BRAVE_DIR/Local State"

    cat <<EOF

    Reset complete.
      Backup:  $BACKUP

    Next steps:
      1. Run: darwin-rebuild switch --flake ~/projects/personal/nix#mac-work
         (activation will seed fresh Personal/ and Work/ directories)
      2. Launch Brave — both profiles appear in the picker with the
         right names; sign in to Google in each.
    EOF
  '';
in
{
  home.packages = [ resetScript ];

  # Idempotent seed. Each guard checks for the target file/directory
  # and only writes if missing, so the activation is a no-op once
  # Brave has taken ownership of these files.
  home.activation.seedBraveProfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -eu
    BRAVE_DIR=${lib.escapeShellArg braveSupport}
    $DRY_RUN_CMD mkdir -p "$BRAVE_DIR"

    ${lib.concatMapStringsSep "\n" (name: ''
      if [[ ! -d "$BRAVE_DIR"/${lib.escapeShellArg name} ]]; then
        echo "Seeding Brave profile: ${name}"
        $DRY_RUN_CMD mkdir -p "$BRAVE_DIR"/${lib.escapeShellArg name}
        $DRY_RUN_CMD install -m 600 ${seedPreferences name} \
          "$BRAVE_DIR"/${lib.escapeShellArg name}/Preferences
      fi
    '') profileNames}

    if [[ ! -f "$BRAVE_DIR/Local State" ]]; then
      echo "Seeding Brave Local State"
      $DRY_RUN_CMD install -m 600 ${seedLocalState} "$BRAVE_DIR/Local State"
    fi
  '';
}
