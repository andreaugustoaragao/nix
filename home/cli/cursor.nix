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
  # Agent Hub is an optional user-local tool; absence is a harmless no-op.
  agentHubHook = {
    command = ''if [ -x "${config.home.homeDirectory}/.local/bin/agent-hub" ]; then "${config.home.homeDirectory}/.local/bin/agent-hub" cursor-hook; else printf '{}\n'; fi'';
  };
  # Cursor / cursor-agent reads ~/.cursor/hooks.json for hook registration.
  # The format mirrors Claude Code's hook config in spirit: a list of
  # event entries, each with a matcher and a command to invoke.
  #
  # The `pi-rs hook cursor` adapter writes the agent-expected envelope
  # (`{"permission":"allow","updated_input":{"command":...}}` on rewrite,
  # `{}` on passthrough). See home/cli/pi-rs/crates/pi-rs/src/cmd/hook.rs.
  hooks = pkgs.writeText "cursor-hooks.json" (
    builtins.toJSON {
      version = 1;
      hooks = {
        sessionStart = [
          agentHubHook
          {
            command = "bash '${config.home.homeDirectory}/.cursor/herdr-agent-state.sh' session";
          }
        ];
        sessionEnd = [ agentHubHook ];
        beforeSubmitPrompt = [ agentHubHook ];
        afterAgentResponse = [ agentHubHook ];
        postToolUse = [ agentHubHook ];
        stop = [ (agentHubHook // { loop_limit = 1; }) ];
        preToolUse = [
          {
            matcher = "Bash";
            command = "${piRs}/share/pi-rs/agent-hooks/cursor-rewrite.sh";
          }
          agentHubHook
        ];
      };
    }
  );
  configureHooks = arguments: ''
    run ${lib.getExe pkgs.python3} ${./agent-json-configure.py} \
      --kind cursor \
      --target ${lib.escapeShellArg "${config.home.homeDirectory}/.cursor/hooks.json"} \
      --desired ${hooks} \
      --state ${lib.escapeShellArg "${config.xdg.stateHome}/agent-json/cursor.json"} \
      --legacy "''${oldGenPath:-}/home-files/.cursor/hooks.json" ${arguments}
  '';
in
{
  home.activation.cursorHooksPrepare =
    lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ]
      (configureHooks "--prepare");
  home.activation.cursorHooks = lib.hm.dag.entryAfter [ "linkGeneration" ] (configureHooks "");

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
