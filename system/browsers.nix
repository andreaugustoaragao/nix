{ lib, ... }:

# Managed policies for Chromium-based browsers.
#
# Brave and Chromium both honor Chromium's enterprise policy mechanism
# (Chrome / Chromium read /etc/chromium/policies/managed/*.json; Brave
# reads /etc/brave/policies/managed/*.json). Anything pinned here is
# enforced — the UI shows "managed by your administrator" and the user
# cannot override it. This is the strongest declarative lever we have
# for Brave; UX prefs that don't have a policy equivalent (vertical
# tabs, wide URL bar) are seeded via home/desktop/brave-profiles.nix.
#
# Policy reference:
#   https://chromeenterprise.com/policies/  (Chromium-wide)
#   https://github.com/brave/brave-core/blob/master/components/policy/  (Brave-specific)
# Policy names are verified against the running brave binary's symbol
# table (`strings brave | grep -E '^Brave.*(Enabled|Disabled)$'`).
#
# The ${user_home} substitution is expanded by the browser at runtime,
# so the same policy works for every user.

let
  # Chrome Web Store IDs for the extensions we force-install. Same IDs
  # work in any Chromium-based browser. Single source of truth — the
  # ExtensionSettings policy below + the Bitwarden 3rdparty config
  # below both read from here.
  extensionIds = {
    bitwarden = "nngceckbapebfimnlniiiahkandclblb";
    vimium = "dbepggeogbaibhgnhhndojpepiihcmeb";
    markdownViewer = "ckkdlimhmcjmikdlpkmbgfkaikojcbjk";
  };

  # ExtensionSettings spec applied to every force-installed extension.
  #   force_installed → auto-install on profile creation, block any
  #                     uninstall attempt. The extension shows up with
  #                     the "managed" badge in brave://extensions.
  #   force_pinned    → toolbar icon is always visible; user can't
  #                     unpin it.
  forceInstalledAndPinned = {
    installation_mode = "force_installed";
    update_url = "https://clients2.google.com/service/update2/crx";
    toolbar_pin = "force_pinned";
  };

  # Policies recognized by every Chromium-based browser. Disabling the
  # built-in password manager pushes everything to Bitwarden; disabling
  # the bookmark bar matches the minimal-chrome preference. Passkeys
  # off because Bitwarden owns those too.
  commonPolicies = {
    DownloadDirectory = "\${user_home}/downloads";
    BookmarkBarEnabled = false;
    PasswordManagerEnabled = false;
    PasswordManagerPasskeysEnabled = false;
  };

  # Brave-specific kill switches. Each maps to a feature surfaced in
  # the toolbar, NTP, or sidebar; turning them off via policy removes
  # the corresponding UI affordance (rather than just hiding it
  # cosmetically) and survives Brave updates.
  bravePolicies = commonPolicies // {
    BraveRewardsDisabled = true;
    BraveAIChatEnabled = false; # Leo
    BraveVPNDisabled = true;
    TorDisabled = true; # private window with Tor
    BraveNewsDisabled = true;
    BraveTalkDisabled = true;
    BraveWalletDisabled = true;

    # Force-install + force-pin Bitwarden, Vimium, Markdown Viewer in
    # every profile. Stronger than home-manager's programs.brave.
    # extensions (which only drops an External Extensions JSON and
    # lets the user disable/remove afterwards). The Claude-in-Chrome
    # extension stays in the HM list because we don't need it pinned.
    ExtensionSettings = lib.genAttrs (lib.attrValues extensionIds) (_: forceInstalledAndPinned);

    # Bitwarden's own managed-storage schema only exposes environment
    # URLs (see managed_schema.json shipped with the extension). The
    # `base` URL is enough — the extension derives api/identity/icons/
    # etc. from it by default. Pointing at the self-hosted Vaultwarden
    # makes both profiles default to that vault on first login.
    "3rdparty".extensions."${extensionIds.bitwarden}".environment.base = "https://vw.faragao.net";
  };
in
{
  # Chromium reads /etc/chromium/policies/managed/*.json. Brave-
  # specific keys are ignored by Chromium, so keep this set focused
  # on policies Chromium actually honors.
  programs.chromium = {
    enable = true;
    extraOpts = commonPolicies;
  };

  # Brave reads /etc/brave/policies/managed/*.json.
  environment.etc."brave/policies/managed/00-default.json".text = builtins.toJSON bravePolicies;
}
