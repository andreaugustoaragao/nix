{
  config,
  lib,
  pkgs,
  isServer ? false,
  ...
}:

let
  herdr = pkgs.callPackage ../../pkgs/herdr.nix { };
  instructions = builtins.readFile ./agent-host-instructions.md;
  context = pkgs.writeShellScriptBin "agent-host-context" ''
    exec ${lib.getExe pkgs.python3} ${./agent-host-context.py} "$@"
  '';
  skillRoots = [
    ".agents/skills"
    ".cursor/skills"
    ".grok/skills"
    ".gemini/skills"
    ".qwen/skills"
    "${lib.removePrefix "${config.home.homeDirectory}/" config.xdg.configHome}/opencode/skills"
  ];
  skills = {
    orca = pkgs.writeTextDir "SKILL.md" ''
      ---
      name: orca
      description: Identify Orca terminal or structured-session context and use Orca worktrees, terminals, agents, or its embedded browser when requested.
      ---

      # Orca

      Run `agent-host-context` in the current shell tool. Orca terminals expose
      `ORCA_PANE_KEY`; structured sessions expose `ORCA_STRUCTURED_SESSION=1`
      and `ORCA_AGENT_SESSION_ID`. Multiple hosts' markers can coexist.

      Select the CLI once, following Orca's discovery contract:

      - Use `ORCA_CLI_COMMAND` when set.
      - Otherwise, in a development checkout with `ORCA_DEV_REPO_ROOT`, use
        `orca-dev`.
      - On Linux outside an Orca-managed terminal, use `orca-ide`. Bare `orca`
        can be the GNOME screen reader. Structured sessions are not PTYs.
      - Otherwise use the managed `orca` executable.

      With that executable, run `skills get orca-cli` before host operations.
      The guide is embedded in the installed version. Use its `--help` for
      exact arguments and prefer `--json`. If the selected CLI fails, report
      its error rather than silently switching to another runtime.

      For orchestration, load `skills get orchestration --full`. Follow the
      current task's delegation scope. For Orca's embedded browser, use the
      Orca guide; `browser-task` manages separate browser profiles.

      Orca installs its own agent hooks/plugins in writable agent config.
      Keep those alongside Nix's Herdr hooks. Do not copy TUI socket hooks to
      Orca or run an installer over a Nix-owned skill. This Nix routing skill
      is separate from Orca's native `orca-cli` discovery stub.
    '';
    terminal-host = pkgs.writeTextDir "SKILL.md" ''
      ---
      name: terminal-host
      description: Identify the current terminal host or diagnose missing Herdr TUI, Herdr Desktop, or Orca context. Use before choosing host control commands.
      ---

      ${instructions}
    '';
    herdr = pkgs.runCommand "herdr-routing-skill" { } ''
      mkdir -p "$out/references"
      cp ${herdr}/share/herdr/skill/SKILL.md "$out/references/tui.md"
      cp ${./herdr-skill.md} "$out/SKILL.md"
    '';
    herdr-core = pkgs.writeTextDir "SKILL.md" ''
      ---
      name: herdr-core
      description: Control herdr-core terminals or the Herdr Desktop window when requested. Detect the current terminal with HC_TERMINAL_ID, not HERDR_ENV or TERM_PROGRAM.
      ---

      # Herdr Desktop and core

      Run `agent-host-context` in the current shell tool. A nonempty
      `HC_TERMINAL_ID` identifies your core terminal; `HC_TERMINAL_SOCKET`
      identifies its owner. Preserve this environment when invoking `hc`.
      If context is missing, establish the intended core with the user before
      controlling a default session.

      Run `hc --skill` for the installed CLI's current manual. For Desktop
      spaces, tabs, layouts, or mods, also run `herdr-app --skill`.
      Use `hc` for core terminals and `herdr-app` for the window.

      Codex launches inside core need `--no-daemon`; the Nix launcher adds it.
      Core status uses OSC 7501 from the terminal program. Legacy Herdr socket
      hooks do not provide core status. A program may have no status report.
      Follow the task's delegation scope when using the manual's agent examples.
      Only clean up terminals you created for this task.
    '';
  };
in
{
  home.packages = [
    context
    (pkgs.callPackage ../../pkgs/herdr-core.nix { })
  ];

  home.file = lib.mkMerge [
    (lib.listToAttrs (
      lib.concatMap (
        root:
        lib.mapAttrsToList (name: source: {
          name = "${root}/${name}";
          value = { inherit source; };
        }) skills
      ) skillRoots
    ))
    {
      ".codex/AGENTS.md".text = lib.mkAfter instructions;
      ".pi/agent/AGENTS.md".text = lib.mkAfter instructions;
    }
  ];

  xdg.configFile = lib.mkIf (!isServer) {
    "herdr-core/config.toml" = {
      force = true;
      source = (pkgs.formats.toml { }).generate "herdr-core-config.toml" {
        shell = [ (lib.getExe pkgs.fish) ];
      };
    };
    "opencode/AGENTS.md".text = lib.mkAfter instructions;
  };
}
