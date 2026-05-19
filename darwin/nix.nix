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
      # Sunday 03:00 — fully specified so launchd doesn't treat the
      # missing Hour/Minute as wildcards (which it does with partial
      # StartCalendarInterval keys). Lands well before nix-optimise's
      # default Sunday 04:15 slot so the optimise pass doesn't waste
      # cycles hard-linking generations gc is about to delete.
      interval = {
        Weekday = 0;
        Hour = 3;
        Minute = 0;
      };
      options = "--delete-older-than 30d";
    };
  };

  nixpkgs.config.allowUnfree = true;
}
