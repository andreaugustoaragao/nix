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
      # The cask catalog and the brew binary have to move together.
      # Freezing updates left Homebrew 5.1.12 reading a catalog that
      # uses `command_wrapper` and structured `run` steps, which aborted
      # the bundle on chromium, firefox, and orbstack. Homebrew only
      # auto-updates when the last fetch is older than a day.
      autoUpdate = true;
      upgrade = true;
      # Homebrew 7 disabled `brew bundle --cleanup` ("no replacement")
      # and expects `--force-cleanup` again, which is what nix-darwin
      # emits for cleanup = "zap" (along with `--zap`).
      cleanup = "zap";
    };

    # Third-party taps. nix-darwin runs `brew tap` for each of these on
    # activation. Homebrew 7 will not load them until they are trusted,
    # and `brew bundle --force-cleanup` resets the trust store to whatever
    # the Brewfile declares, so the trust has to live here.
    taps = [
      {
        name = "nikitabobko/tap"; # aerospace tiling window manager
        trusted = true;
      }
      {
        name = "FelixKratz/formulae"; # JankyBorders (focused-window outline daemon)
        trusted = true;
      }
      {
        name = "sadiksaifi/tap"; # mac-menu (native Swift fuzzy picker, dmenu/fuzzel shape)
        trusted = true;
      }
    ];

    # Formulae and casks come from machines.toml so the Linux side of
    # the flake stays unaware of brew. Defaults are empty lists.
    brews = homebrewBrews;
    casks = homebrewCasks;
  };
}
