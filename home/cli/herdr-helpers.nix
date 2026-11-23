{
  lib,
  pkgs,
  hostName,
  ...
}:

let
  ompEnabled = builtins.elem hostName [
    "prl-dev-vm"
    "workstation"
    "workstation-worker"
    "gcp-agent-wk"
  ];
  cursorStatus = pkgs.writeShellApplication {
    name = "herdr-cursor-status";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./herdr-helpers/cursor-status.sh;
  };
  cursorPlugin = pkgs.runCommand "herdr-cursor-status-plugin" { } ''
    mkdir -p "$out/.cursor-plugin" "$out/hooks"
    cat > "$out/.cursor-plugin/plugin.json" <<'EOF'
    ${builtins.toJSON {
      name = "herdr-cursor-status";
      version = "1.0.0";
      description = "Report Cursor worker lifecycle status to Herdr Desktop";
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
      if [[ "$1" == auto ]] || ! cursor-agent models | cut -d' ' -f1 | grep -Fxq -- "$1"; then
        echo "Unavailable explicit Cursor worker model: $1" >&2
        exit 1
      fi
      if [[ -z "''${HC_TERMINAL_ID:-}" ]]; then
        echo 'herdr-cursor must be launched in a herdr-core terminal with hc run.' >&2
        exit 1
      fi
      HERDR_COORDINATE_TTY=$(tty)
      export HERDR_COORDINATE_TTY
      HERDR_COORDINATE_STATE_DIR=$(mktemp -d "''${TMPDIR:-/tmp}/herdr-cursor.XXXXXXXX")
      export HERDR_COORDINATE_STATE_DIR
      trap 'rm -rf -- "$HERDR_COORDINATE_STATE_DIR"' EXIT
      instructions=$(cat ${./herdr-helpers/implementer.md})
      cursor-agent --plugin-dir ${cursorPlugin} --model "$1" "$instructions"$'\n\n'"$2"
    '';
  };
  codexName = pkgs.writeShellApplication {
    name = "herdr-codex-name";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${./herdr-helpers/codex-name.py} "$@"
    '';
  };
in
{
  home.packages = [
    cursor
    cursorStatus
    codexName
  ];

  xdg.configFile = lib.optionalAttrs ompEnabled {
    "herdr-core/templates/dev-review.md".text = ''
      ---
      description: Independent read-only code review with OMP (gpt-6.2-astra, xhigh effort, LSP enabled).
      command: omp --model litellm/gpt-6.2-astra --thinking xhigh --tools read,grep,glob,ast_grep,lsp --no-extensions
      ---
      ${builtins.readFile ./herdr-helpers/reviewer.md}
    '';
  };
}
