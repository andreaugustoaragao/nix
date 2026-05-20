{
  pkgs,
  config,
  ...
}:

# macOS ssh-agent equivalent of the Linux setup in home/cli/gpg.nix.
#
# Why a custom one: macOS 13+ stopped auto-starting the per-user
# `com.openssh.ssh-agent` LaunchAgent, and the SSH_AUTH_SOCK that
# remains in user env points at a stale socket that nothing listens
# on. We start our own ssh-agent on a stable, well-known socket so
# shells and GUI apps can hard-code SSH_AUTH_SOCK.
#
# Keys are preloaded at login using sops-decrypted passphrase files,
# fed to `ssh-add` via SSH_ASKPASS — same trick gpg.nix uses on
# Linux. Subsequent shells / git invocations talk to the agent and
# never see a prompt.

let
  homeDir = config.home.homeDirectory;
  sshAuthSock = "${homeDir}/.ssh/agent.sock";

  # SSH_ASKPASS helper. ssh-add reads the passphrase from this
  # program's stdout; the caller decides which file via $KEY_PASS_FILE.
  loadKeysAskpass = pkgs.writeShellScript "ssh-load-keys-askpass" ''
    exec ${pkgs.coreutils}/bin/cat "$KEY_PASS_FILE"
  '';

  # The single launchd agent process: bind ssh-agent to our well-known
  # socket, preload both keys, then wait on the agent so KeepAlive can
  # restart us if it dies.
  startAndLoad = pkgs.writeShellScript "ssh-agent-startup" ''
    set -uo pipefail

    # Tear down a stale socket left over from a previous session, then
    # start ssh-agent in foreground bound to that path. -D keeps it
    # attached so launchd's KeepAlive can supervise it.
    rm -f "${sshAuthSock}"
    "${pkgs.openssh}/bin/ssh-agent" -a "${sshAuthSock}" -D &
    AGENT_PID=$!

    # Wait for the socket to actually exist before we feed keys to it.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -S "${sshAuthSock}" ] && break
      sleep 0.1
    done

    export SSH_AUTH_SOCK="${sshAuthSock}"

    add_key() {
      local key="$1" pass="$2"
      [ -r "$key" ]  || { echo "ssh-load-keys: $key missing";  return 0; }
      # sops-install-secrets and our agent both run at login; if the
      # passphrase isn't materialized yet, poll briefly.
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -r "$pass" ] && break
        sleep 0.5
      done
      [ -r "$pass" ] || { echo "ssh-load-keys: $pass missing"; return 0; }

      KEY_PASS_FILE="$pass" \
      SSH_ASKPASS="${loadKeysAskpass}" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=":0" \
        "${pkgs.openssh}/bin/ssh-add" "$key" </dev/null
    }

    add_key "${homeDir}/.ssh/id_rsa_personal" "/run/secrets/ssh_passphrase_personal"
    add_key "${homeDir}/.ssh/id_rsa_work"     "/run/secrets/ssh_passphrase_work"

    # Fleet identity key — generated locally by `nix run .#fleet-bootstrap`,
    # never enters sops. No passphrase, so we bypass ASKPASS entirely and
    # call ssh-add directly. Missing key is non-fatal (host hasn't run
    # bootstrap yet).
    fleet_key="${homeDir}/.ssh/id_ed25519_fleet"
    if [ -r "$fleet_key" ]; then
      "${pkgs.openssh}/bin/ssh-add" "$fleet_key" </dev/null
    else
      echo "ssh-load-keys: $fleet_key missing (run: nix run .#fleet-bootstrap)"
    fi

    # Block on ssh-agent so launchd treats the job as alive.
    wait "$AGENT_PID"
  '';
in
{
  launchd.agents.ssh-agent = {
    enable = true;
    config = {
      Label = "org.nix-home.ssh-agent";
      ProgramArguments = [ "${startAndLoad}" ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${homeDir}/Library/Logs/ssh-agent.log";
      StandardErrorPath = "${homeDir}/Library/Logs/ssh-agent.log";
    };
  };

  # Hard-code SSH_AUTH_SOCK so every shell and child process talks to
  # our agent rather than macOS's stale default.
  home.sessionVariables.SSH_AUTH_SOCK = sshAuthSock;

  # Shell rc files load before sessionVariables on macOS in some cases
  # (terminal apps started outside a login shell), so also export
  # explicitly from each shell's init.
  programs.fish.interactiveShellInit = ''
    set -gx SSH_AUTH_SOCK "${sshAuthSock}"
  '';
  programs.zsh.initContent = ''
    export SSH_AUTH_SOCK="${sshAuthSock}"
  '';
  programs.bash.initExtra = ''
    export SSH_AUTH_SOCK="${sshAuthSock}"
  '';
}
