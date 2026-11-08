{
  config,
  lib,
  isServer ? false,
  ...
}:

let
  instructions = ''
    # Project locations

    Keep the home directory clean. Always create personal projects under
    `${config.home.homeDirectory}/projects/personal` and work-related projects
    under `${config.home.homeDirectory}/projects/work`.

    This applies to new repositories, clones, scaffolds, and Git worktrees.
    Never create project directories directly in `${config.home.homeDirectory}`,
    even when the session starts there. Choose the category from the task's
    context; ask if it is unclear whether a new project is personal or work.
    Keep project artifacts inside the project directory and use `/tmp` for
    disposable scratch files.
  '';
in
{
  home.file = {
    ".codex/AGENTS.md".text = lib.mkAfter instructions;
    ".pi/agent/AGENTS.md".text = lib.mkAfter instructions;
    ".claude/rules/project-locations.md".text = instructions;
  };

  xdg.configFile = lib.mkIf (!isServer) {
    "opencode/AGENTS.md".text = lib.mkAfter instructions;
  };
}
