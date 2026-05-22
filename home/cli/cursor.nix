{
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
}
