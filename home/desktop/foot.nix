_:

{
  # foot reads the freedesktop color-scheme preference and picks
  # [colors-light] vs [colors-dark] accordingly — live-switch works
  # out of the box (no signal/SIGUSR1 needed). The bare [colors]
  # `alpha=` applies to both modes.
  programs.foot = {
    enable = true;
    settings = {
      main = {
        font = "CaskaydiaMono Nerd Font:size=11";
        font-bold = "CaskaydiaMono Nerd Font:style=Bold:size=11";
        font-italic = "CaskaydiaMono Nerd Font:style=Italic:size=11";
        dpi-aware = "no";
        pad = "5x5";
        shell = "fish";
      };

      colors = {
        alpha = "0.98";
      };

      "colors-dark" = {
        foreground = "cdd6f4";
        background = "1e1e2e";
        selection-foreground = "cdd6f4";
        selection-background = "45475a";

        regular0 = "45475a";
        regular1 = "f38ba8";
        regular2 = "a6e3a1";
        regular3 = "f9e2af";
        regular4 = "89b4fa";
        regular5 = "f5c2e7";
        regular6 = "94e2d5";
        regular7 = "bac2de";

        bright0 = "585b70";
        bright1 = "f38ba8";
        bright2 = "a6e3a1";
        bright3 = "f9e2af";
        bright4 = "89b4fa";
        bright5 = "f5c2e7";
        bright6 = "94e2d5";
        bright7 = "a6adc8";
      };

      "colors-light" = {
        foreground = "4c4f69";
        background = "eff1f5";
        selection-foreground = "4c4f69";
        selection-background = "ccd0da";

        regular0 = "5c5f77";
        regular1 = "d20f39";
        regular2 = "40a02b";
        regular3 = "df8e1d";
        regular4 = "1e66f5";
        regular5 = "ea76cb";
        regular6 = "179299";
        regular7 = "acb0be";

        bright0 = "6c6f85";
        bright1 = "d20f39";
        bright2 = "40a02b";
        bright3 = "df8e1d";
        bright4 = "1e66f5";
        bright5 = "ea76cb";
        bright6 = "179299";
        bright7 = "4c4f69";
      };
    };
  };
}
