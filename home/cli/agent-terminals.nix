{
  lib,
  pkgs,
  isServer ? false,
  ...
}:

let
  instructions = builtins.readFile ./agent-host-instructions.md;
  context = pkgs.writeShellScriptBin "agent-host-context" ''
    exec ${lib.getExe pkgs.python3} ${./agent-host-context.py} "$@"
  '';
  skillRoots = [
    ".agents/skills"
    ".cursor/skills"
  ];
  skills = {
    terminal-host = pkgs.writeTextDir "SKILL.md" ''
      ---
      name: terminal-host
      description: Identify the current terminal host or diagnose missing Herdr Desktop/core context. Use before choosing host control commands.
      ---

      ${instructions}
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

      ## Naming & layout rules

      - **Lead tab per space:** each space has one `lead` tab (`herdr.role=lead`,
        first tab by default). Open child agents on separate worker tabs in the
        same space with up to 4 splits per tab, never inside `lead`.
      - **Spaces (`herdr-app do space.new --name`):** use `<repo>` for a main
        checkout, `<repo> · <worktree-or-branch>` for a linked worktree, and
        disambiguate with `· <topic>` if a space for that repo already exists.
      - **Tabs (`herdr-app do tab.new --name`):** use a concise topic or task
        name (e.g. `Auth review`, `T020 · Fast startup`); never leave `"1"` or
        bare harness names when creating a task tab.
      - **Terminals & splits (`hc run --name`, `hc label`):** pass a kebab-case
        `--name <topic-or-task>-<role>` (e.g. `t020-impl`, `auth-review`,
        `nix-check`) to `hc run`. For splits created via `pane.split` /
        `terminal.open` / `terminal.keep`, set `hc label <t> herdr.name=<role>`
        so pane headers and agent lists display the role.
      - Preserve user-named spaces, tabs, and explicit `herdr.name` labels.
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
      ".omp/agent/AGENTS.md".text = lib.mkAfter instructions;
    }
  ];

  xdg.configFile = lib.mkIf (!isServer) {
    "herdr-core/config.toml" = {
      force = true;
      source = (pkgs.formats.toml { }).generate "herdr-core-config.toml" {
        shell = [ (lib.getExe pkgs.fish) ];
      };
    };
  };
}
