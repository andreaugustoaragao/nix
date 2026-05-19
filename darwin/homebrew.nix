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
      cleanup = "zap"; # remove anything not declared here
      upgrade = true;
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
