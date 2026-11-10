{ lib, pkgs, ... }:

let
  skill = builtins.path {
    name = "chief-of-staff-skill";
    path = ./chief-of-staff;
  };
  cursorStatus = pkgs.writeShellApplication {
    name = "herdr-cursor-status";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
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
    runtimeInputs = [
      pkgs.coreutils
      cursorStatus
    ];
    text = ''
      if [[ $# -ne 2 ]]; then
        echo 'Usage: herdr-cursor MODEL TASK' >&2
        exit 1
      fi
      case "$1" in
        grok-4.7-high|grok-4.7-xhigh|composer-2.5) ;;
        *) echo "Unsupported development worker model: $1" >&2; exit 1 ;;
      esac
      if [[ -z "''${HC_TERMINAL_ID:-}" ]]; then
        echo 'herdr-cursor must be launched in a herdr-core terminal with hc run.' >&2
        exit 1
      fi
      HERDR_COORDINATE_TTY=$(tty)
      export HERDR_COORDINATE_TTY
      HERDR_COORDINATE_STATE_DIR=$(mktemp -d "''${TMPDIR:-/tmp}/herdr-cursor.XXXXXXXX")
      export HERDR_COORDINATE_STATE_DIR
      trap 'rm -rf -- "$HERDR_COORDINATE_STATE_DIR"' EXIT
      instructions=$(cat ${./herdr-coordinate/implementer.md})
      cursor-agent --plugin-dir ${cursorPlugin} --model "$1" "$instructions"$'\n\n'"$2"
    '';
  };
in
{
  home.packages = [
    cursor
    cursorStatus
  ];

  home.file = {
    ".agents/skills/chief-of-staff".source = skill;
    # Preserve the old invocation without a second coordinator or worker pool.
    ".agents/skills/herdr-coordinate".source = builtins.path {
      name = "herdr-coordinate-compatibility-skill";
      path = ./herdr-coordinate;
    };
  };

  xdg.configFile = {
    "herdr-core/templates/dev-review.md".text = ''
      ---
      description: Independent read-only code review with Codex Astra, xhigh effort.
      command: codex --model gpt-6-astra -c 'model_reasoning_effort="xhigh"' --sandbox read-only
      ---
      ${builtins.readFile ./herdr-coordinate/reviewer.md}
    '';
  };
}
