{ lib, pkgs, ... }:

let
  skill = builtins.path {
    name = "herdr-coordinate-skill";
    path = ./herdr-coordinate;
  };
  cursorStatus = pkgs.writeShellApplication {
    name = "herdr-cursor-status";
    runtimeInputs = [ pkgs.jq ];
    text = builtins.readFile ./herdr-coordinate/cursor-status.sh;
  };
  cursorPlugin = pkgs.runCommand "herdr-coordinate-cursor-plugin" { } ''
    mkdir -p "$out/.cursor-plugin" "$out/hooks"
    cat > "$out/.cursor-plugin/plugin.json" <<'EOF'
    ${builtins.toJSON {
      name = "herdr-coordinate-status";
      version = "1.0.0";
      description = "Report coordinated Cursor workers' lifecycle to Herdr Desktop";
    }}
    EOF
    cat > "$out/hooks/hooks.json" <<'EOF'
    ${builtins.toJSON {
      version = 1;
      hooks = {
        beforeSubmitPrompt = [ { command = lib.getExe cursorStatus; } ];
        stop = [ { command = lib.getExe cursorStatus; } ];
      };
    }}
    EOF
  '';
  cursor = pkgs.writeShellApplication {
    name = "herdr-cursor";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [[ -z "''${HC_TERMINAL_ID:-}" ]]; then
        echo 'herdr-cursor must be launched in a herdr-core terminal with hc run.' >&2
        exit 1
      fi
      HERDR_COORDINATE_TTY=$(tty)
      export HERDR_COORDINATE_TTY
      exec cursor-agent --plugin-dir ${cursorPlugin} "$@"
    '';
  };
  implementer = builtins.readFile ./herdr-coordinate/implementer.md;
  worker = model: ''
    ---
    description: Scoped implementation with ${model}; separate worktree required for edits.
    command: ${lib.getExe cursor} --model ${model}
    ready: quiet
    submit: enter
    stop: ctrl+c
    ---
    ${implementer}
  '';
in
{
  home.packages = [
    cursor
    cursorStatus
  ];

  home.file.".agents/skills/herdr-coordinate".source = skill;

  xdg.configFile = {
    "herdr-core/templates/dev-grok.md".text = worker "grok-4.7-high";
    "herdr-core/templates/dev-grok-xhigh.md".text = worker "grok-4.7-xhigh";
    "herdr-core/templates/dev-composer.md".text = worker "composer-2.5";
    "herdr-core/templates/dev-review.md".text = ''
      ---
      description: Independent read-only code review with Codex Astra, xhigh effort.
      command: codex --model gpt-6-astra -c 'model_reasoning_effort="xhigh"' --sandbox read-only
      ---
      ${builtins.readFile ./herdr-coordinate/reviewer.md}
    '';
  };
}
