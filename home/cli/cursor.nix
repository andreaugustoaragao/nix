{
  config,
  lib,
  pkgs,
  ...
}:

let
  # pi-rs token-compression binary + materialized shim scripts.
  # preToolUse hook routes Bash commands through `pi-rs hook cursor`.
  piRs = pkgs.callPackage ./pi-rs { };
in
{
  # Cursor / cursor-agent reads ~/.cursor/hooks.json for hook registration.
  # The format mirrors Claude Code's hook config in spirit: a list of
  # event entries, each with a matcher and a command to invoke.
  #
  # The `pi-rs hook cursor` adapter writes the agent-expected envelope
  # (`{"permission":"allow","updated_input":{"command":...}}` on rewrite,
  # `{}` on passthrough). See home/cli/pi-rs/crates/pi-rs/src/cmd/hook.rs.
  home.file.".cursor/hooks.json".text = builtins.toJSON {
    version = 1;
    hooks = {
      preToolUse = [
        {
          matcher = "Bash";
          command = "${piRs}/share/pi-rs/agent-hooks/cursor-rewrite.sh";
        }
      ];
    };
  };

  # cursor-agent stores runtime state (model picker, auth) in
  # ~/.cursor/cli-config.json. Merge vimMode on activation so we do not
  # overwrite fields the CLI manages itself.
  home.activation.cursorCliConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="${config.home.homeDirectory}/.cursor/cli-config.json"
    mkdir -p "$(dirname "$target")"
    if [[ -f "$target" ]]; then
      existing="$(cat "$target")"
    else
      existing='{"permissions":{"allow":[],"deny":[]},"version":1}'
    fi
    printf '%s' "$existing" \
      | ${pkgs.jq}/bin/jq '.editor = ((.editor // {}) + {vimMode: true})' \
      > "$target.tmp"
    mv "$target.tmp" "$target"
    chmod 0600 "$target"
  '';
}
