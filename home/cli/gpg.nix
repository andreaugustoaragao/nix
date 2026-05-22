{
  pkgs,
  lib,
  owner,
  ...
}:

let
  # Symlink → /dev/null masks a user systemd unit (same trick as
  # `systemctl --user mask`, but declarative).
  maskedUnit = pkgs.runCommand "masked-systemd-unit" { } "ln -s /dev/null $out";

  # ASKPASS helper. ssh-add reads the passphrase from the program's
  # stdout; this just cats whatever passphrase file the caller picked
  # via $KEY_PASS_FILE. Used at session start to preload both keys
  # without prompting.
  loadKeysAskpass = pkgs.writeShellScript "ssh-load-keys-askpass" ''
    exec ${pkgs.coreutils}/bin/cat "$KEY_PASS_FILE"
  '';

  # Add the personal + work keys to the running ssh-agent at session
  # start, pulling each passphrase from its sops-deployed file. With
  # both keys cached, neither ksshaskpass nor gcr-prompter ever has a
  # reason to fire — including for desktop-launched git callers like
  # Fulcrum's Bun app.
  loadKeysScript = pkgs.writeShellScript "ssh-load-keys" ''
    set -uo pipefail

    add_key() {
      local key="$1" pass="$2"
      [ -r "$key" ] || { echo "ssh-load-keys: $key missing"; return 0; }
      [ -r "$pass" ] || { echo "ssh-load-keys: $pass missing"; return 0; }
      KEY_PASS_FILE="$pass" \
      SSH_ASKPASS="${loadKeysAskpass}" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=:0 \
        ${pkgs.openssh}/bin/ssh-add "$key" </dev/null
    }

    add_key "/home/${owner.name}/.ssh/id_rsa_personal" "/run/secrets/ssh_passphrase_personal"
    add_key "/home/${owner.name}/.ssh/id_rsa_work"     "/run/secrets/ssh_passphrase_work"
  '';
in
{
  # GPG configuration with secure settings
  programs.gpg = {
    enable = true;
    settings = {
      # Use AES256 for symmetric encryption
      cipher-algo = "AES256";
      # Use SHA512 for hashing
      digest-algo = "SHA512";
      # Use SHA512 for certifications
      cert-digest-algo = "SHA512";
      # Disable weak digest algorithms
      weak-digest = "SHA1";
      # Use stronger compression
      compress-algo = "2";
      # Disable inclusion of version in output
      no-emit-version = true;
      # Disable comments in output
      no-comments = true;
      # Use long keyids
      keyid-format = "0xlong";
      # Show fingerprints
      with-fingerprint = true;
      # Cross-certify subkeys
      require-cross-certification = true;
      # Use gpg-agent
      use-agent = true;
    };
  };

  # GPG Agent configuration (for signing only, not SSH)
  services.gpg-agent = {
    enable = true;
    # Cache timeout settings (long TTL for unattended agent operations)
    defaultCacheTtl = 43200; # 12 hours
    maxCacheTtl = 43200; # 12 hours
    # Disable SSH support - we're using regular SSH keys
    enableSshSupport = false;
    # Use proper pinentry for GPG (ksshaskpass is not compatible with GPG protocol)
    pinentry.package = pkgs.pinentry-qt;
    # Extra configuration
    extraConfig = ''
      # Allow loopback pinentry for automated operations
      allow-loopback-pinentry
      # Allow gpg-preset-passphrase to cache passphrases indefinitely
      allow-preset-passphrase
      # Disable external cache
      no-allow-external-cache
    '';
  };

  # SSH agent configuration with extended timeout
  services.ssh-agent = {
    enable = true;
  };

  # Override SSH agent service to add timeout configuration and consistent socket path
  systemd.user.services.ssh-agent = {
    Service = {
      # Override the default ssh-agent command with no timeout for unattended agents
      # -t 0 = keys never expire, -a sets consistent socket path
      ExecStart = lib.mkForce "${pkgs.openssh}/bin/ssh-agent -D -t 0 -a %t/ssh-agent";
      # Push SSH_AUTH_SOCK into the user-systemd manager environment so
      # desktop-launched apps (Fulcrum's Bun process, browser PWAs, etc.)
      # — which inherit user-systemd's env, NOT the shell's — talk to
      # this agent instead of falling back to the masked gcr-ssh-agent.
      ExecStartPost = "${pkgs.systemd}/bin/systemctl --user set-environment SSH_AUTH_SOCK=%t/ssh-agent";
    };
  };

  # Mask gcr-ssh-agent so it doesn't claim SSH_AUTH_SOCK in user-systemd
  # env (was the sole reason desktop-launched git ops kept popping
  # ksshaskpass / gcr-prompter on every call). Gnome-keyring's secret
  # storage / libsecret still works — this kills only its SSH-agent role.
  home.file.".config/systemd/user/gcr-ssh-agent.socket".source = maskedUnit;
  home.file.".config/systemd/user/gcr-ssh-agent.service".source = maskedUnit;

  # Preload both SSH keys at session start using passphrases from sops,
  # so neither this user nor any desktop-launched child ever sees a
  # passphrase prompt during normal use.
  systemd.user.services.ssh-load-keys = {
    Unit = {
      Description = "Preload personal + work SSH keys into ssh-agent";
      After = [ "ssh-agent.service" ];
      Requires = [ "ssh-agent.service" ];
      PartOf = [ "ssh-agent.service" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = "yes";
      Environment = "SSH_AUTH_SOCK=%t/ssh-agent";
      ExecStart = "${loadKeysScript}";
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Auto-preset GPG passphrases after gpg-agent starts
  systemd.user.services.gpg-preset-keys = {
    Unit = {
      Description = "Preset GPG passphrases from SOPS secrets";
      After = [
        "gpg-agent.service"
        "sops-nix.service"
      ];
      Wants = [ "gpg-agent.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
      ExecStart = "${pkgs.writeShellScript "gpg-preset-keys" ''
        export PATH="${
          lib.makeBinPath [
            pkgs.gnupg
            pkgs.gawk
            pkgs.coreutils
          ]
        }:$PATH"
        LIBEXEC="${pkgs.gnupg}/libexec"

        preset_key() {
          local email="$1" passphrase_file="$2"
          [[ -n "$email" ]] || return 0
          [[ -f "$passphrase_file" ]] || return 0
          local passphrase
          passphrase=$(cat "$passphrase_file" 2>/dev/null)
          [[ -n "$passphrase" && "$passphrase" != "placeholder" ]] || return 0
          gpg --list-secret-keys "$email" >/dev/null 2>&1 || return 0
          gpg --list-secret-keys --with-colons --with-keygrip "$email" \
            | awk -F: '/^grp:/ {print $10}' \
            | while IFS= read -r grip; do
                "$LIBEXEC/gpg-preset-passphrase" --preset --passphrase "$passphrase" "$grip"
              done
        }

        # Work email comes from sops (kept out of /nix/store). On an
        # unprovisioned host the file is absent or contains the
        # "placeholder" sentinel; in that case work_email stays empty
        # and preset_key no-ops on the early return above.
        work_email=""
        WORK_EMAIL_FILE="/run/secrets/git_email_work"
        if [[ -f "$WORK_EMAIL_FILE" ]]; then
          candidate="$(cat "$WORK_EMAIL_FILE" 2>/dev/null)"
          if [[ -n "$candidate" && "$candidate" != "placeholder" ]]; then
            work_email="$candidate"
          fi
        fi

        preset_key "andrearag@gmail.com" "/run/secrets/gpg_passphrase_personal"
        preset_key "$work_email" "/run/secrets/gpg_passphrase_work"
      ''}";
      RemainAfterExit = true;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Cross-platform programs.ssh lives in home/cli/ssh-config.nix so the
  # github-personal / github-work aliases also apply on macOS.

  # Environment setup for the SSH agent + askpass. The SOPS age key
  # on Linux lives at /var/lib/sops-nix/key.txt (root-only), so we
  # don't export SOPS_AGE_KEY_FILE in the user's session — instead
  # the `sops-edit` shell function (home/cli/fish.nix, home/cli/zsh.nix)
  # invokes sops via sudo with the host key. See `sops-edit --help`
  # equivalent: read the function body for the workflow.
  home.sessionVariables = {
    SSH_ASKPASS = "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";
    SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";
  };

  programs.bash.initExtra = ''
    export SSH_ASKPASS="${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
  '';

  programs.fish.interactiveShellInit = ''
    set -gx SSH_ASKPASS "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
    set -gx SSH_AUTH_SOCK "$XDG_RUNTIME_DIR/ssh-agent"
  '';

  programs.zsh.initContent = lib.mkBefore ''
    export SSH_ASKPASS="${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
  '';

  # Install GPG-related packages
  home.packages = with pkgs; [
    gnupg
    paperkey # For backing up GPG keys to paper
    kdePackages.ksshaskpass # For SSH passphrase prompts in GUI
    pinentry-qt # For GPG passphrase prompts in GUI
  ];

  # Auto-import GPG keys from sops-managed secrets (if available)
  home.activation.importGPG = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # Import personal GPG key if it exists and is not a placeholder
    GPG_PERSONAL="/run/secrets/gpg_key_personal"
    if [[ -f "$GPG_PERSONAL" ]] && [[ "$(cat $GPG_PERSONAL)" != "placeholder" ]]; then
      ${pkgs.gnupg}/bin/gpg --batch --import "$GPG_PERSONAL" 2>/dev/null || true
      # Set ultimate trust for imported personal key
      PERSONAL_KEYID=$(${pkgs.gnupg}/bin/gpg --list-keys --with-colons andrearag@gmail.com | ${pkgs.gawk}/bin/awk -F: '/^pub:/ {print $5}' | ${pkgs.coreutils}/bin/head -1)
      if [[ -n "$PERSONAL_KEYID" ]]; then
        echo "$PERSONAL_KEYID:6:" | ${pkgs.gnupg}/bin/gpg --batch --import-ownertrust 2>/dev/null || true
      fi
    fi

    # Import work GPG key if it exists and is not a placeholder.
    # The lookup-by-UID step requires the work email (which is
    # employer-revealing, so it lives in sops). On a host where
    # /run/secrets/git_email_work hasn't been deployed yet we skip
    # the trust-setting step entirely — the key still gets imported,
    # we just don't mark it ultimately trusted.
    GPG_WORK="/run/secrets/gpg_key_work"
    if [[ -f "$GPG_WORK" ]] && [[ "$(cat $GPG_WORK)" != "placeholder" ]]; then
      ${pkgs.gnupg}/bin/gpg --batch --import "$GPG_WORK" 2>/dev/null || true

      WORK_EMAIL_FILE="/run/secrets/git_email_work"
      WORK_EMAIL=""
      if [[ -f "$WORK_EMAIL_FILE" ]]; then
        candidate="$(${pkgs.coreutils}/bin/cat "$WORK_EMAIL_FILE")"
        if [[ -n "$candidate" && "$candidate" != "placeholder" ]]; then
          WORK_EMAIL="$candidate"
        fi
      fi

      if [[ -n "$WORK_EMAIL" ]]; then
        WORK_KEYID=$(${pkgs.gnupg}/bin/gpg --list-keys --with-colons "$WORK_EMAIL" | ${pkgs.gawk}/bin/awk -F: '/^pub:/ {print $5}' | ${pkgs.coreutils}/bin/head -1)
        if [[ -n "$WORK_KEYID" ]]; then
          echo "$WORK_KEYID:6:" | ${pkgs.gnupg}/bin/gpg --batch --import-ownertrust 2>/dev/null || true
        fi
      fi
    fi
  '';
}
