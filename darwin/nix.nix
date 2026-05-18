{ ... }:

{
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Use all CPU cores per build; pick parallel build count automatically.
      cores = 0;
      max-jobs = "auto";

      # NOTE: do NOT set `auto-optimise-store` on Darwin — current
      # nix versions warn it can corrupt the store. Use the periodic
      # `nix.optimise` block below instead.

      # nix-darwin runs the daemon as root; trust the primary user so
      # `nix build` from a normal shell uses the daemon's substituters
      # without prompting.
      trusted-users = [
        "root"
        "@admin"
      ];
    };

    optimise = {
      automatic = true;
    };

    gc = {
      automatic = true;
      interval.Weekday = 0; # Sunday
      options = "--delete-older-than 30d";
    };
  };

  nixpkgs.config.allowUnfree = true;
}
