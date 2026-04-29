{
  config,
  pkgs,
  lib,
  inputs,
  useDms ? false,
  ...
}:

{
  programs.foot = {
    enable = true;
    # When DMS owns the theme, we write foot.ini ourselves below so we
    # can place an `include = …` at the top (home-manager's settings
    # generator can't emit pre-section directives). The Nix-managed
    # settings stay in charge of layout/font/etc when not in DMS mode.
    settings = lib.mkIf (!useDms) {
      main = {
        font = "CaskaydiaMono Nerd Font:size=9";
        font-bold = "CaskaydiaMono Nerd Font:style=Bold:size=9";
        font-italic = "CaskaydiaMono Nerd Font:style=Italic:size=9";
        dpi-aware = "no";
        pad = "5x5";
        shell = "fish";
      };

      colors = {
        alpha = "0.98";

        foreground = "dcd7ba";
        background = "1f1f28";

        regular0 = "090618"; # black
        regular1 = "c34043"; # red
        regular2 = "76946a"; # green
        regular3 = "c0a36e"; # yellow
        regular4 = "7e9cd8"; # blue
        regular5 = "957fb8"; # magenta
        regular6 = "6a9589"; # cyan
        regular7 = "c8c093"; # white

        bright0 = "727169"; # bright black
        bright1 = "e82424"; # bright red
        bright2 = "98bb6c"; # bright green
        bright3 = "e6c384"; # bright yellow
        bright4 = "7fb4ca"; # bright blue
        bright5 = "938aa9"; # bright magenta
        bright6 = "7aa89f"; # bright cyan
        bright7 = "dcd7ba"; # bright white
      };
    };
  };

  # In DMS mode, write foot.ini directly so we can include DMS's
  # matugen-generated palette before the [main] section.
  xdg.configFile."foot/foot.ini" = lib.mkIf useDms {
    text = ''
      include=~/.config/foot/dank-colors.ini

      [main]
      font=CaskaydiaMono Nerd Font:size=9
      font-bold=CaskaydiaMono Nerd Font:style=Bold:size=9
      font-italic=CaskaydiaMono Nerd Font:style=Italic:size=9
      dpi-aware=no
      pad=5x5
      shell=fish

      [colors]
      alpha=0.98
    '';
  };
}
