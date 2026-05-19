{
  pkgs,
  lib,
  ...
}:
# macOS GPG setup. The Linux sibling in home/cli/gpg.nix is heavily
# systemd-user wired (gpg-agent service, gpg-preset-keys oneshot,
# gcr-ssh-agent masking, ksshaskpass) — none of that ports cleanly to
# Darwin. This module does the smaller macOS-shaped job:
#
#   - install gnupg + pinentry_mac
#   - drop a gpg-agent.conf pointing at pinentry_mac with a long
#     cache TTL so a sign per session is enough
#   - import the personal + work secret keys from
#     /run/secrets/gpg_key_* on every activation (idempotent)
#
# Passphrase caching: pinentry_mac's first prompt offers "Save in
# Keychain". After that the macOS Keychain unlocks the GPG passphrase
# silently for the rest of the login session. No launchd preset job
# needed.
#
# Signing key wiring stays in home/cli/git.nix — same `gpg.program =
# gnupg` and same long-form key IDs as on Linux, so this module is
# purely about making `gpg --sign` work.
{
  programs.gpg = {
    enable = true;
    settings = {
      cipher-algo = "AES256";
      digest-algo = "SHA512";
      cert-digest-algo = "SHA512";
      weak-digest = "SHA1";
      compress-algo = "2";
      no-emit-version = true;
      no-comments = true;
      keyid-format = "0xlong";
      with-fingerprint = true;
      require-cross-certification = true;
      use-agent = true;
    };
  };

  # programs.gpg doesn't expose a Darwin-friendly gpg-agent option, so
  # write the agent config directly. gpg auto-spawns gpg-agent on first
  # use using these settings; no launchd unit needed.
  home.file.".gnupg/gpg-agent.conf".text = ''
    pinentry-program ${pkgs.pinentry_mac}/Applications/pinentry-mac.app/Contents/MacOS/pinentry-mac
    default-cache-ttl 43200
    max-cache-ttl 43200
    allow-loopback-pinentry
  '';

  home.packages = [
    pkgs.gnupg
    pkgs.pinentry_mac
  ];

  # Import GPG keys from sops-managed secrets. Same approach as the
  # Linux activation in gpg.nix — gpg --import is idempotent (it
  # silently no-ops if the key is already in the keyring), so this is
  # safe to run on every activation.
  home.activation.importGPG = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    GPG=${pkgs.gnupg}/bin/gpg
    AWK=${pkgs.gawk}/bin/awk
    HEAD=${pkgs.coreutils}/bin/head
    CAT=${pkgs.coreutils}/bin/cat

    import_key() {
      local secret="$1" email="$2"
      [[ -f "$secret" ]] || return 0
      [[ "$($CAT "$secret")" != "placeholder" ]] || return 0
      $DRY_RUN_CMD $GPG --batch --import "$secret" 2>/dev/null || true
      local keyid
      keyid=$($GPG --list-keys --with-colons "$email" \
        | $AWK -F: '/^pub:/ {print $5}' | $HEAD -1)
      if [[ -n "$keyid" ]]; then
        echo "$keyid:6:" \
          | $DRY_RUN_CMD $GPG --batch --import-ownertrust 2>/dev/null || true
      fi
    }

    import_key /run/secrets/gpg_key_personal andrearag@gmail.com
    import_key /run/secrets/gpg_key_work     aragao@avaya.com
  '';
}
