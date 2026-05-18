{ ... }:

# Linux-only module: home-manager's `xdg.desktopEntries` only exists on
# Linux (the option itself is undefined on Darwin, so we can't just gate
# the value with mkIf — the attribute name has to be absent entirely).
# Therefore this lives in its own file, imported only on Linux from
# home/cli/default.nix.

{
  # Local .desktop overrides for packages whose Icon= references a name
  # not in the active icon theme (Papirus-Dark). User-local entries win
  # over the package-provided ones in the XDG search path.
  xdg.desktopEntries = {
    yazi = {
      name = "Yazi";
      comment = "Blazing fast terminal file manager written in Rust";
      exec = "yazi %u";
      terminal = true;
      type = "Application";
      mimeType = [ "inode/directory" ];
      categories = [
        "Utility"
        "FileTools"
        "FileManager"
        "ConsoleOnly"
      ];
      icon = "system-file-manager";
    };

    # khal ships no Icon= field at all.
    khal = {
      name = "ikhal";
      genericName = "Calendar application";
      comment = "Terminal CLI calendar application";
      exec = "ikhal";
      terminal = true;
      type = "Application";
      categories = [
        "Calendar"
        "ConsoleOnly"
      ];
      icon = "office-calendar";
    };

    # blueman ships Icon=blueman-device which isn't in Papirus.
    blueman-adapters = {
      name = "Bluetooth Adapters";
      comment = "Set Bluetooth Adapter Properties";
      exec = "blueman-adapters";
      terminal = false;
      type = "Application";
      categories = [
        "Settings"
        "HardwareSettings"
      ];
      icon = "blueman";
    };
  }
  // (
    # CLI/TUI .desktop entries shipped by various packages that pollute
    # fuzzel without being useful as no-arg launches. `noDisplay = true`
    # hides them from launchers (user override beats package-provided in
    # the XDG search path) while keeping MIME handlers intact.
    let
      hide = name: {
        inherit name;
        noDisplay = true;
        # `exec` is mandatory in HM's xdg.desktopEntries schema even when
        # the entry is hidden; point at /bin/true so the file is well-formed.
        exec = "true";
      };
    in
    {
      vim = hide "Vim";
      tectonic = hide "Tectonic";
      "amdgpu_top-tui" = hide "AMDGPU TOP (TUI)";
      bottom = hide "bottom";
      btop = hide "btop++";
      htop = hide "Htop";
      # `nvim.desktop` is the package-provided "Neovim wrapper" entry —
      # not a wrapper for Neovide, just stock terminal nvim with a
      # misleading upstream name. Neovide stays visible for the genuine
      # GUI-launch case.
      nvim = hide "Neovim wrapper";
      # Foot terminal — keep the plain `foot.desktop` for at-will use;
      # hide the server/client pair (daemon mode, unused here).
      footclient = hide "Foot Client";
      foot-server = hide "Foot Server";

      # Moved from home/cli/tmux.nix so the tmux module itself stays
      # cross-platform.
      tmux-sessionizer = {
        name = "Tmux Project";
        genericName = "Tmux session picker";
        comment = "Pick a project and attach or create its tmux session";
        exec = "tmux-sessionizer";
        terminal = true;
        type = "Application";
        categories = [
          "Utility"
          "TerminalEmulator"
          "ConsoleOnly"
        ];
        icon = "utilities-terminal";
      };
    }
  );
}
