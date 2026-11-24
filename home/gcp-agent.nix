{
  config,
  lib,
  pkgs,
  owner,
  ...
}:
{
  imports = [
    ./appearance
    ./cli
    ./fonts.nix
    ./services/litellm.nix
    ./services/pi-models.nix
  ];

  home = {
    username = owner.name;
    homeDirectory = "/home/${owner.name}";
    stateVersion = "26.05";
    sessionPath = [ "$HOME/.local/bin" ];
    sessionVariables = {
      GOOGLE_CLOUD_PROJECT = "core-optimized-lab";
      SCCACHE_DIR = "${config.home.homeDirectory}/.cache/sccache";
      SCCACHE_CACHE_SIZE = "40G";
    };
    packages = [
      (pkgs.callPackage ../pkgs/herdr-core.nix { })
      pkgs.sccache
    ];
  };

  # Generate a dedicated SSH key for Git commit/tag signing (never reusing
  # workstation GPG keys on the cloud VM) and populate allowed_signers.
  home.activation.gcpSigningKey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -eu
    ssh_dir="${config.home.homeDirectory}/.ssh"
    key="$ssh_dir/id_ed25519_signing"
    pub="$key.pub"
    allowed="$ssh_dir/allowed_signers"

    mkdir -p "$ssh_dir"
    chmod 0700 "$ssh_dir"
    if [ ! -f "$key" ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -C "aragao@gcp-aragao-agent-wk-signing" -f "$key" >/dev/null
    fi
    chmod 0600 "$key"
    chmod 0644 "$pub"

    pub_content="$(${pkgs.coreutils}/bin/cat "$pub")"
    {
      printf 'andrearag@gmail.com %s\n' "$pub_content"
      if [ -r /run/secrets/git_email_work ]; then
        work_email="$(${pkgs.coreutils}/bin/cat /run/secrets/git_email_work)"
        if [ -n "$work_email" ] && [ "$work_email" != "placeholder" ]; then
          printf '%s %s\n' "$work_email" "$pub_content"
        fi
      fi
    } > "$allowed.tmp"
    chmod 0600 "$allowed.tmp"
    mv "$allowed.tmp" "$allowed"
  '';
  programs.home-manager.enable = true;
  _module.args.wallpapers = lib.mkDefault null;
}
