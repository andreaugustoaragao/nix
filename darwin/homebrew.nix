{
  homebrewCasks,
  homebrewBrews,
  ...
}:

{
  # nix-darwin's homebrew module wraps brew so casks/formulae are
  # installed/uninstalled to match this list on every activation.
  # We DO NOT auto-install Homebrew itself — bootstrap that once via
  # the official installer before the first `darwin-rebuild switch`.
  homebrew = {
    enable = true;

    onActivation = {
      autoUpdate = false; # don't slow down rebuilds
      upgrade = true;
      # nix-darwin-26.05 still emits `--force-cleanup` when cleanup is
      # "uninstall" or "zap". Current Homebrew dropped that flag
      # (`Error: invalid option: --force-cleanup`) and restored
      # `--cleanup` / `--zap` on `brew bundle`. Keep nix-darwin's
      # cleanup enum at "none" and pass the live flags ourselves until
      # nix-darwin-26.05 catches up.
      cleanup = "none";
      extraFlags = [
        "--cleanup"
        "--zap"
      ];
    };

    # Third-party taps. AeroSpace is shipped from its author's tap
    # rather than homebrew-cask. nix-darwin runs `brew tap` for each
    # of these on activation, so the casks below can reference them
    # without fully-qualified names.
    taps = [
      "nikitabobko/tap" # aerospace tiling window manager
      "FelixKratz/formulae" # JankyBorders (focused-window outline daemon)
      "sadiksaifi/tap" # mac-menu (native Swift fuzzy picker, dmenu/fuzzel shape)
    ];

    # Formulae and casks come from machines.toml so the Linux side of
    # the flake stays unaware of brew. Defaults are empty lists.
    brews = homebrewBrews;
    casks = homebrewCasks;
  };
}
