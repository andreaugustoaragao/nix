{
  config,
  lib,
  pkgs,
  ...
}:
let
  gh = pkgs.writeShellScriptBin "gh" ''
    set -eu
    if [ -z "''${GH_TOKEN:-}''${GITHUB_TOKEN:-}" ]; then
      test -r /run/secrets/github_token || {
        echo 'Worker GitHub credential is not provisioned.' >&2
        exit 1
      }
      GH_TOKEN="$(${pkgs.coreutils}/bin/cat /run/secrets/github_token)"
      export GH_TOKEN
    fi
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  signing =
    identity:
    pkgs.writeShellScript "worker-gpg-${identity}" ''
      set -eu
      exec ${pkgs.gnupg}/bin/gpg --batch --pinentry-mode loopback \
        --passphrase-fd 3 "$@" 3</run/secrets/gpg_passphrase_${identity}
    '';
  personalSigning = signing "personal";
  workSigning = signing "work";
  askpass = pkgs.writeShellScript "worker-git-ssh-askpass" ''
    case "''${WORKER_GIT_SSH_PASSPHRASE_FILE:-}" in
      /run/secrets/ssh_passphrase_personal|/run/secrets/ssh_passphrase_work)
        exec ${pkgs.coreutils}/bin/cat -- "$WORKER_GIT_SSH_PASSPHRASE_FILE" ;;
      *) exit 1 ;;
    esac
  '';
  loadKeys = pkgs.writeShellScript "worker-git-ssh-keys" ''
    exec ${pkgs.python3}/bin/python3 ${./worker-git-credentials.py} refresh \
      --home ${lib.escapeShellArg config.home.homeDirectory} \
      --state ${lib.escapeShellArg "${config.xdg.stateHome}/worker-git-credentials"} \
      --secret-directory /run/secrets \
      --ssh-add ${pkgs.openssh}/bin/ssh-add \
      --ssh-keygen ${pkgs.openssh}/bin/ssh-keygen \
      --askpass ${askpass}
  '';
in
{
  home.packages = [ (lib.hiPrio gh) ];
  home.file.".ssh/known_hosts_github".source = ./worker-github-known-hosts;
  programs.ssh.settings =
    lib.genAttrs
      [
        "github.com"
        "github-personal"
        "github-work"
      ]
      (_: {
        StrictHostKeyChecking = "yes";
        UserKnownHostsFile = "${config.home.homeDirectory}/.ssh/known_hosts_github";
      });
  programs.git = {
    settings = {
      gpg.program = lib.mkForce (toString personalSigning);
      gpg.openpgp.program = lib.mkForce (toString personalSigning);
      core.sshCommand = "${pkgs.coreutils}/bin/env SSH_AUTH_SOCK=/run/user/1000/ssh-agent ${pkgs.openssh}/bin/ssh -o BatchMode=yes";
      credential."https://github.com".helper = lib.mkForce "!${gh}/bin/gh auth git-credential";
      credential."https://gist.github.com".helper = lib.mkForce "!${gh}/bin/gh auth git-credential";
    };
    includes = lib.mkAfter [
      {
        condition = "gitdir:${config.home.homeDirectory}/projects/work/";
        contents.gpg = {
          program = toString workSigning;
          openpgp.program = toString workSigning;
        };
      }
    ];
  };
  programs.gpg.enable = true;
  services.gpg-agent = {
    enable = true;
    enableSshSupport = false;
    pinentry.package = pkgs.pinentry-curses;
    extraConfig = "allow-loopback-pinentry";
  };
  services.ssh-agent.enable = true;
  systemd.user.services.ssh-agent.Service.ExecStart =
    lib.mkForce "${pkgs.openssh}/bin/ssh-agent -D -t 0 -a %t/ssh-agent";
  systemd.user.services.worker-git-ssh-keys = {
    Unit = {
      Description = "Load SOPS Git identities for headless worker commands";
      Requires = [ "ssh-agent.service" ];
      After = [ "ssh-agent.service" ];
      PartOf = [ "ssh-agent.service" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "SSH_AUTH_SOCK=%t/ssh-agent";
      ExecStart = toString loadKeys;
    };
    Install.WantedBy = [ "default.target" ];
  };
  home.sessionVariables.SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";
  home.activation.importWorkerGitSigningKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    for identity in personal work; do
      key="/run/secrets/gpg_key_$identity"
      if [ ! -r "$key" ]; then
        echo "Worker Git signing identity is not provisioned: $identity" >&2
        exit 1
      fi
      ${pkgs.gnupg}/bin/gpg --batch --quiet --import "$key" >/dev/null 2>&1 || {
        echo "Could not import worker Git signing identity: $identity" >&2
        exit 1
      }
    done
  '';
}
