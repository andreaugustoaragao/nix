{
  config,
  pkgs,
  lib,
  ...
}:
# Reproducible Brave profile bring-up. Used on both Linux and macOS.
#
# Problem: Brave/Chromium's --profile-directory flag (used by
# home/scripts/browser-app.nix on Linux and the web-app .app bundles
# in web-apps-macos.nix on Darwin) keys off the on-disk directory
# name, not the display name shown in the profile picker. Without a
# controlled seed, Brave auto-creates Default/ on first launch (shown
# as "Person 1") and any --profile-directory=Foo dirs it creates
# afterwards get display names auto-assigned to "Person N", drifting
# away from what the web-apps-data.nix entries reference.
#
# Solution: seed two directories named after the displayed profile so
# the on-disk name and the display name stay in lockstep —
#   Personal/  → profile.name = "Personal"
#   Work/      → profile.name = "Work"
# That makes `--profile-directory=Personal` and
# `--profile-directory=Work` resolve unambiguously.
#
# Workflow for a clean rebuild:
#   1. Quit Brave.
#   2. Run `brave-profiles-reset` — backs up the whole Brave-Browser
#      dir to a timestamped sibling, then removes Default/Personal/Work
#      and Local State.
#   3. Rebuild — activation reseeds the Personal/ and Work/ skeletons:
#        Linux : sudo nixos-rebuild switch --flake .#$(hostname)
#        macOS : darwin-rebuild switch --flake .#mac-work
#   4. Launch Brave; sign into each profile via brave://settings.
#
# After step 4 Brave owns these files. Activation is a no-op on every
# subsequent rebuild — it only seeds when a target file is missing.
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  # Brave's on-disk layout differs by platform.
  braveSupport =
    if isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/BraveSoftware/Brave-Browser"
    else
      "${config.xdg.configHome}/BraveSoftware/Brave-Browser";

  # `pgrep -x` matches the full process name. macOS launches the bundle
  # as "Brave Browser"; Linux runs the `brave` binary directly.
  braveProcessPattern = if isDarwin then "Brave Browser" else "brave";

  # Single source of truth. Directory name == display name == the
  # value passed as `profile = ...` in home/desktop/web-apps-data.nix.
  profileNames = [
    "Personal"
    "Work"
  ];

  # Seed Preferences. Brave rewrites this file constantly while
  # running, but it reads what's on disk at startup, so a fresh profile
  # picks up these as initial values. profile.name pins the picker
  # label; the brave.* keys give us the desired UX on first launch
  # (vertical tabs collapsed into a hover strip, wide URL bar). None
  # of these have policy equivalents — they're plain prefs — so this
  # is best-effort: the user can later toggle via brave://settings, and
  # changes only re-apply after `brave-profiles-reset` + rebuild.
  seedPreferences =
    name:
    pkgs.writeText "brave-${name}-preferences.json" (
      builtins.toJSON {
        profile = {
          inherit name;
        };
        brave = {
          tabs = {
            # Tab strip on the side instead of across the top.
            vertical_tabs_enabled = true;
            # Start collapsed (icons only, narrow strip).
            vertical_tabs_collapsed = true;
            # Hovering the collapsed strip floats it open temporarily
            # — the "mouse-over mode" — and snaps back on mouse-out.
            vertical_tabs_floating_enabled = true;
          };
          # "Wide URL bar" in brave://settings/appearance. Stretches
          # the omnibox to span the full width of the window.
          location_bar_is_wide = true;
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

  rebuildHint =
    if isDarwin then
      "darwin-rebuild switch --flake ~/projects/personal/nix#mac-work"
    else
      "sudo nixos-rebuild switch --flake ~/projects/personal/nix#$(hostname)";

  resetScript = pkgs.writeShellScriptBin "brave-profiles-reset" ''
    set -euo pipefail
    BRAVE_DIR=${lib.escapeShellArg braveSupport}

    if pgrep -x ${lib.escapeShellArg braveProcessPattern} >/dev/null 2>&1; then
      echo "Brave is running. Quit it and re-run." >&2
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
      1. Run: ${rebuildHint}
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
