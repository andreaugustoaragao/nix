{
  config,
  osConfig ? { },
  lib,
  pkgs,
  hostName,
  ...
}:
let
  caBundle = osConfig.environment.variables.SSL_CERT_FILE or "";

  # Immutable root activator invoked via macOS's native GUI SecurityAgent
  # (`osascript ... with administrator privileges`). Validates the built
  # store path, updates `/nix/var/nix/profiles/system`, and executes the
  # closure's own `activate` script without re-evaluating the mutable repo.
  activator = pkgs.writeShellApplication {
    name = "darwin-nix-rebuild-activate";
    runtimeInputs = [
      pkgs.nix
      pkgs.coreutils
    ];
    text = ''
      if [ "$#" -ne 1 ]; then
        echo "Usage: darwin-nix-rebuild-activate <darwin-system-store-path>" >&2
        exit 2
      fi
      system_path="$1"
      case "$system_path" in
        /nix/store/*-darwin-system-*) ;;
        *)
          echo "Refusing invalid darwin system path: $system_path" >&2
          exit 2
          ;;
      esac
      if [ ! -x "$system_path/activate" ]; then
        echo "Missing executable activate script in $system_path" >&2
        exit 2
      fi

      # osascript strips user environment variables when elevating; restore
      # the standard Nix/system PATH and corporate CA bundle so `brew bundle`
      # and Nix activation steps succeed behind Netskope.
      export HOME=~root
      export NIX_REMOTE=daemon
      export PATH="/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      ${lib.optionalString (caBundle != "") ''
        export SSL_CERT_FILE=${lib.escapeShellArg caBundle}
        export NIX_SSL_CERT_FILE=${lib.escapeShellArg caBundle}
        export CURL_CA_BUNDLE=${lib.escapeShellArg caBundle}
        export GIT_SSL_CAINFO=${lib.escapeShellArg caBundle}
      ''}

      nix-env -p /nix/var/nix/profiles/system --set "$system_path"
      exec "$system_path/activate"
    '';
  };

  settings = pkgs.writeText "darwin-nix-rebuild.json" (
    builtins.toJSON {
      repository = "${config.home.homeDirectory}/projects/personal/nix";
      hostname = hostName;
      git = lib.getExe pkgs.git;
      nix = lib.getExe pkgs.nix;
      activator = lib.getExe activator;
      osascript = "/usr/bin/osascript";
      launchctl = "/bin/launchctl";
    }
  );

  darwinNixRebuild = pkgs.writeShellApplication {
    name = "darwin-nix-rebuild";
    text = ''
      exec ${lib.getExe pkgs.python3} ${./darwin-nix-rebuild.py} --config ${settings} "$@"
    '';
  };
in
{
  home.packages = [ darwinNixRebuild ];
}
