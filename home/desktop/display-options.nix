# Typed option surface for the canonical display-slot metadata.
#
# The flake thinks in two logical slots: dp1 (landscape primary) and
# dp2 (portrait secondary). Which Wayland connector each slot maps to,
# and how big the dp2 slot is in scaled pixels, are per-host facts —
# resolved in flake.nix (machines.toml override, else a profile-based
# default) and delivered here via specialArgs.
#
# This module is the single point where those specialArgs enter the
# module system: it declares `my.displays.*` with types and docs, and
# seeds the values at mkDefault priority so any host or module can
# still override with a plain assignment. Consumers (niri.nix,
# quickshell.nix) read `config.my.displays.*` instead of re-declaring
# function-argument defaults that drift from flake.nix.
{
  lib,
  displays,
  dp2Dimensions,
  ...
}:

{
  options.my.displays = {
    dp1 = lib.mkOption {
      type = lib.types.str;
      description = ''
        Wayland connector name of the dp1 slot — the landscape primary
        output (right side on the workstation). DP-1 on bare metal,
        Virtual-1 under Parallels/VMware, eDP-1 on laptops.
      '';
      example = "DP-1";
    };

    dp2 = lib.mkOption {
      type = lib.types.str;
      description = ''
        Wayland connector name of the dp2 slot — the portrait secondary
        output (left side on the workstation).
      '';
      example = "DP-2";
    };

    dp2Dimensions = {
      width = lib.mkOption {
        type = lib.types.ints.positive;
        description = ''
          Logical width of the dp2 slot in scaled pixels. Used to
          compute dp1's x-offset in niri and to anchor DMS desktop
          widgets (cava) flush with the dp2 bottom edge.
        '';
        example = 1440;
      };

      height = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Logical height of the dp2 slot in scaled pixels.";
        example = 2560;
      };
    };
  };

  config.my.displays = {
    dp1 = lib.mkDefault displays.dp1;
    dp2 = lib.mkDefault displays.dp2;
    dp2Dimensions = {
      width = lib.mkDefault dp2Dimensions.width;
      height = lib.mkDefault dp2Dimensions.height;
    };
  };
}
