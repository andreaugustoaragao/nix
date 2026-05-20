{ config, lib, ... }:

# AeroSpace tiling-WM config, mirroring the niri keymap from
# home/desktop/niri.nix as closely as an i3-style tiler permits.
#
# Key differences from niri (impossible to mirror exactly):
#   - niri is *scrollable*-tiling (columns slide horizontally, infinite
#     row); AeroSpace is BSP/tiles. There is no analog for
#     consume-or-expel, switch-preset-column-width, or
#     toggle-column-tabbed-display. We approximate `Mod+c` with
#     `layout accordion horizontal` (collapses siblings into a tab-like
#     strip).
#   - niri uses `Mod` = Super (the macOS Cmd key). On macOS, Cmd
#     conflicts heavily with system shortcuts (Cmd+W closes app,
#     Cmd+Q quits, Cmd+Space is Spotlight). We use **Alt (Option)** as
#     the mod so Cmd-based shortcuts in apps keep working unchanged.
#     If you want a Super-like feel, change `alt-` to `cmd-` below and
#     accept the conflicts.
#   - macOS reserves Mission Control / Mac workspaces; AeroSpace
#     advises disabling "Automatically rearrange Spaces based on most
#     recent use" in System Settings → Desktop & Dock before use.

let
  # AeroSpace launches under launchd at login with a sparse PATH
  # (`/usr/bin:/bin:/usr/sbin:/sbin`). nix-installed scripts live in
  # `/etc/profiles/per-user/<user>/bin/`, which is NOT on that PATH, so
  # bare `aerospace-window-switcher` / `app-launcher` resolved to
  # nothing. Reference the user's home-manager profile directly so the
  # exec-and-forget bindings hit the real store path on every launch.
  binPath = "${config.home.profileDirectory}/bin";
in
{
  xdg.configFile."aerospace/aerospace.toml".text = ''
    # Start AeroSpace at login. brew installs a launchd agent; this
    # toggle makes it active on first activation.
    start-at-login = true

    # macOS "Spaces" interferes with multi-monitor focus. AeroSpace
    # docs recommend disabling the corresponding system setting; this
    # flag avoids fighting it when it's on.
    #
    # Also launches JankyBorders (`borders`, from FelixKratz/formulae,
    # declared in machines.toml/darwin/homebrew.nix) — a tiny daemon
    # that paints a colored outline around the focused window. Tying
    # it to AeroSpace startup means borders comes up and goes down
    # with the WM; no separate LaunchAgent to manage.
    #
    # Colors are Catppuccin Mocha:
    #   - lavender #b4befe → active (focused window)
    #   - surface1 #45475a → inactive (any other tile)
    after-startup-command = [
      'exec-and-forget /opt/homebrew/bin/borders active_color=0xffb4befe inactive_color=0xff45475a width=4.0 style=round hidpi=on'
    ]

    # Smart gaps roughly approximating niri's column spacing.
    [gaps]
    inner.horizontal = 16
    inner.vertical   = 16
    outer.left       = 8
    outer.bottom     = 8
    outer.top        = 8
    outer.right      = 8

    # Niri-style: new windows become a new column to the right of focus.
    # AeroSpace's nearest equivalent — new windows are placed as a
    # sibling of the focused window in the parent container.
    [mode.main.binding]

    # --- Launching apps (parity with niri Mod+Return / Mod+Shift+* /
    #     Mod+Space) ---
    alt-enter        = "exec-and-forget /Applications/Ghostty.app/Contents/MacOS/ghostty"
    alt-space        = "exec-and-forget open -a Raycast"
    alt-d            = "exec-and-forget open -a Raycast"

    # Bitwarden — niri's Mod+Backslash equivalent (see
    # home/desktop/niri.nix). The brew cask installs Bitwarden.app
    # under /Applications; `open -a Bitwarden` foregrounds the
    # existing window if it's already running, otherwise launches it.
    alt-backslash    = "exec-and-forget open -a Bitwarden"

    # Window switcher — niri's Mod+s equivalent. Built on
    # `aerospace list-windows --all` + choose-gui as the fuzzy picker.
    # Script ships from home/cli/aerospace-window-switcher.nix.
    # Note: cmd-s globally would shadow every app's Save shortcut, so
    # we stick with the alt- mod used by the rest of this config.
    alt-s            = "exec-and-forget ${binPath}/aerospace-window-switcher"

    # Selection-screenshot-to-clipboard (Option+Shift+S) is bound at
    # the macOS level via com.apple.symbolichotkeys hotkey #29, see
    # darwin/macos-defaults.nix. Routing it through AeroSpace would
    # race with the WindowServer's own intercept of the same chord.

    # --- Window actions ---
    alt-w            = "close"
    alt-shift-q      = "reload-config"
    alt-f            = "fullscreen"
    alt-f9           = "fullscreen"

    # Floating toggle — niri's Mod+V → toggle-window-floating.
    alt-v            = "layout floating tiling"

    # Tabbed column emulation — niri's Mod+c
    # (toggle-column-tabbed-display).
    alt-c            = "layout accordion horizontal"

    # --- Focus (Mod+hjkl and Mod+arrows) ---
    alt-h            = "focus left"
    alt-j            = "focus down"
    alt-k            = "focus up"
    alt-l            = "focus right"
    alt-left         = "focus left"
    alt-down         = "focus down"
    alt-up           = "focus up"
    alt-right        = "focus right"

    # --- Move windows (Mod+Shift+hjkl / Mod+Shift+arrows) ---
    alt-shift-h      = "move left"
    alt-shift-j      = "move down"
    alt-shift-k      = "move up"
    alt-shift-l      = "move right"
    alt-shift-left   = "move left"
    alt-shift-down   = "move down"
    alt-shift-up     = "move up"
    alt-shift-right  = "move right"

    # --- Workspaces 1..10 (Mod+1..0) ---
    alt-1            = "workspace 1"
    alt-2            = "workspace 2"
    alt-3            = "workspace 3"
    alt-4            = "workspace 4"
    alt-5            = "workspace 5"
    alt-6            = "workspace 6"
    alt-7            = "workspace 7"
    alt-8            = "workspace 8"
    alt-9            = "workspace 9"
    alt-0            = "workspace 10"

    # --- Move container to workspace (Mod+Shift+1..0) ---
    alt-shift-1      = "move-node-to-workspace 1"
    alt-shift-2      = "move-node-to-workspace 2"
    alt-shift-3      = "move-node-to-workspace 3"
    alt-shift-4      = "move-node-to-workspace 4"
    alt-shift-5      = "move-node-to-workspace 5"
    alt-shift-6      = "move-node-to-workspace 6"
    alt-shift-7      = "move-node-to-workspace 7"
    alt-shift-8      = "move-node-to-workspace 8"
    alt-shift-9      = "move-node-to-workspace 9"
    alt-shift-0      = "move-node-to-workspace 10"

    # --- Workspace cycling (Mod+Tab / Mod+Shift+Tab) ---
    alt-tab          = "workspace-back-and-forth"
    alt-shift-tab    = "workspace-back-and-forth"

    # --- Monitor focus (Mod+Ctrl+arrows) ---
    alt-ctrl-left    = "focus-monitor --wrap-around left"
    alt-ctrl-right   = "focus-monitor --wrap-around right"
    alt-ctrl-up      = "focus-monitor --wrap-around up"
    alt-ctrl-down    = "focus-monitor --wrap-around down"

    # --- Move column to other monitor (Mod+Ctrl+Shift+arrows) ---
    alt-ctrl-shift-left  = "move-node-to-monitor --wrap-around left"
    alt-ctrl-shift-right = "move-node-to-monitor --wrap-around right"
    alt-ctrl-shift-up    = "move-node-to-monitor --wrap-around up"
    alt-ctrl-shift-down  = "move-node-to-monitor --wrap-around down"

    # --- Resize (Mod+Minus / Mod+Equal / Mod+Shift+Minus / Mod+Shift+Equal) ---
    alt-minus            = "resize smart -50"
    alt-equal            = "resize smart +50"
    alt-shift-minus      = "resize height -50"
    alt-shift-equal      = "resize height +50"

    # Reset to even split (niri's Mod+R → switch-preset-column-width)
    alt-r            = "balance-sizes"

    # Sublayout toggles — accordion (tab-like) vs tiles vertical/horizontal.
    # No niri analog beyond Mod+c (above); these are AeroSpace idioms.
    alt-leftSquareBracket  = "layout tiles horizontal vertical"
    alt-rightSquareBracket = "layout accordion horizontal vertical"

    # --- Workspace bindings: glue each workspace to a monitor when
    #     two displays are connected. AeroSpace will only enforce this
    #     when both monitor patterns match; otherwise workspaces float.
    [workspace-to-monitor-force-assignment]
    1 = "main"
    2 = "main"
    3 = "main"
    4 = "main"
    5 = "main"
    6 = "secondary"
    7 = "secondary"
    8 = "secondary"
    9 = "secondary"
    10 = "secondary"
  '';

  # Tell the running AeroSpace daemon to re-read ~/.config/aerospace/
  # aerospace.toml after every activation. Without this hook, each
  # darwin-rebuild quietly rewrites the file on disk but the daemon
  # keeps serving the keymap it loaded at last login — bindings drift
  # silently from source until `alt-shift-q` (reload-config) is hit
  # by hand or AeroSpace restarts. Probes `list-modes` first as a
  # cheap IPC-alive check: skip the reload if the daemon is not
  # running yet (first install, pre-login activation, or AeroSpace
  # killed and not yet relaunched). The trailing `|| true` swallows
  # the rare race where AeroSpace is mid-reload from a sibling event.
  home.activation.aerospaceReload = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if /opt/homebrew/bin/aerospace list-modes >/dev/null 2>&1; then
      $DRY_RUN_CMD /opt/homebrew/bin/aerospace reload-config || true
    fi
  '';
}
