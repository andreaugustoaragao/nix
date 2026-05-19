# Single source of truth for the host's daily-driver terminal. Consumer
# modules (niri, hyprland, fuzzel, wofi, waybar, thunar) import this
# with the host's profile flags and read the field they need. To switch
# terminals on a host, change the selection logic below — no
# consumer-side edits required.
#
# Ghostty is the daily driver everywhere except the VMs, where its
# OpenGL renderer demands a GL version the Parallels/VMware guest 3D
# drivers don't expose, so kitty stands in. `--single-instance` folds
# every kitty invocation (Mod+Return, fuzzel-launched desktop entries
# like "Tmux Project", waybar on-click handlers, ...) into a single
# daemon process; ghostty does the same via `gtk-single-instance = true`
# in its own config.

{
  isVm ? false,
}:

let
  useKitty = isVm;
in
if useKitty then
  {
    # Wayland app-id — for window rules, switcher icons, etc.
    appId = "kitty";
    # niri `spawn` is argv-style: this fragment drops directly into the
    # KDL config (already quoted). Bare open.
    spawnArgs = ''"kitty" "--single-instance"'';
    # Bare-open as a shell-exec string (hyprland keybinds, ad-hoc exec
    # lines that don't need to run a follow-up command).
    command = "kitty --single-instance";
    # Prefix for "open a terminal running CMD" — callers append their
    # command. Used by fuzzel `terminal=` / wofi `term`, waybar
    # `on-click` handlers, etc. Kitty treats trailing positional args
    # as the program to run, so no `-e` separator is needed.
    launcherCommand = "kitty --single-instance";
    # Open the terminal with a working directory. `%f` is substituted
    # by the caller (e.g. Thunar's custom-action token).
    openInDirCommand = "kitty --single-instance --directory=%f";
  }
else
  {
    appId = "com.mitchellh.ghostty";
    spawnArgs = ''"ghostty"'';
    command = "ghostty";
    launcherCommand = "ghostty -e";
    openInDirCommand = "ghostty --working-directory=%f";
  }
