{
  lib,
  pkgs,
  ...
}:

# Managed policies for Brave on macOS — Darwin counterpart to
# system/browsers.nix.
#
# On macOS, Chromium/Brave treats ordinary `defaults`
# (~/Library/Preferences, /Library/Preferences) as recommended-only
# (`CFPreferencesAppValueIsForced` is false), which means mandatory
# policies like force-installed extensions are ignored unless delivered
# under `/Library/Managed Preferences/`. Extension managed storage also
# uses a separate preference domain (`<bundle-id>.extensions.<ext-id>`)
# rather than Linux's `"3rdparty"` JSON key.
#
# Jamf manages Chrome (`/Library/Managed Preferences/com.google.Chrome.plist`),
# so we leave Chrome untouched and manage Brave only.
#
# Because macOS ManagedClient can regenerate `/Library/Managed Preferences`
# at boot on Jamf-enrolled hosts, the installer runs both during
# `postActivation` (immediate effect on `darwin-rebuild switch`) and via
# a `RunAtLoad` LaunchDaemon so the plists survive reboots.

let
  extensionIds = {
    bitwarden = "nngceckbapebfimnlniiiahkandclblb";
    vimium = "dbepggeogbaibhgnhhndojpepiihcmeb";
    markdownViewer = "ckkdlimhmcjmikdlpkmbgfkaikojcbjk";
  };

  forceInstalledAndPinned = {
    installation_mode = "force_installed";
    update_url = "https://clients2.google.com/service/update2/crx";
    toolbar_pin = "force_pinned";
  };

  bravePolicies = {
    BookmarkBarEnabled = false;
    PasswordManagerEnabled = false;
    PasswordManagerPasskeysEnabled = false;

    BraveRewardsDisabled = true;
    BraveAIChatEnabled = false; # Leo
    BraveVPNDisabled = true;
    TorDisabled = true;
    BraveNewsDisabled = true;
    BraveTalkDisabled = true;
    BraveWalletDisabled = true;
    ShowFullUrlsInAddressBar = true;

    ExtensionSettings = {
      "fcoeoabgfenejglbffodgkkbkcdhcgfn".installation_mode = "removed";
    }
    // lib.genAttrs (lib.attrValues extensionIds) (_: forceInstalledAndPinned);
  };

  bitwardenManagedStorage = {
    environment.base = "https://vw.faragao.net";
  };

  bravePlistXml = pkgs.writeText "com.brave.Browser.plist" (
    lib.generators.toPlist { escape = true; } bravePolicies
  );

  bitwardenPlistXml = pkgs.writeText "com.brave.Browser.extensions.${extensionIds.bitwarden}.plist" (
    lib.generators.toPlist { escape = true; } bitwardenManagedStorage
  );

  installPolicies = pkgs.writeShellScript "install-brave-managed-policies" ''
    set -euo pipefail

    managed_dir="/Library/Managed Preferences"
    /bin/mkdir -p "$managed_dir"
    /usr/sbin/chown root:wheel "$managed_dir"
    /bin/chmod 755 "$managed_dir"

    changed=0
    install_plist() {
      local src="$1"
      local dest="$managed_dir/$2"
      local tmp
      tmp=$(/usr/bin/mktemp "$managed_dir/.tmp.XXXXXX")
      /usr/bin/plutil -convert binary1 -o "$tmp" "$src"
      /usr/sbin/chown root:wheel "$tmp"
      /bin/chmod 644 "$tmp"
      if [ -f "$dest" ] && /usr/bin/cmp -s "$tmp" "$dest"; then
        /bin/rm -f "$tmp"
      else
        /bin/mv -f "$tmp" "$dest"
        changed=1
      fi
    }

    install_plist "${bravePlistXml}" "com.brave.Browser.plist"
    install_plist "${bitwardenPlistXml}" "com.brave.Browser.extensions.${extensionIds.bitwarden}.plist"

    if [ "$changed" -eq 1 ]; then
      /usr/bin/killall -HUP cfprefsd 2>/dev/null || true
    fi
  '';
in
{
  system.activationScripts.postActivation.text = lib.mkAfter ''
    ${installPolicies}
  '';

  launchd.daemons.brave-managed-policies = {
    serviceConfig = {
      Label = "net.faragao.brave-managed-policies";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "/bin/wait4path /nix/store && exec ${installPolicies}"
      ];
      RunAtLoad = true;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
}
