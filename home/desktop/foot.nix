{ ... }:

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
        foreground = "c0caf5";
        background = "24283b";
        selection-foreground = "c0caf5";
        selection-background = "2e3c64";

        regular0 = "1d202f";
        regular1 = "f7768e";
        regular2 = "9ece6a";
        regular3 = "e0af68";
        regular4 = "7aa2f7";
        regular5 = "bb9af7";
        regular6 = "7dcfff";
        regular7 = "a9b1d6";

        bright0 = "414868";
        bright1 = "f7768e";
        bright2 = "9ece6a";
        bright3 = "e0af68";
        bright4 = "7aa2f7";
        bright5 = "bb9af7";
        bright6 = "7dcfff";
        bright7 = "c0caf5";
      };

      "colors-light" = {
        foreground = "3760bf";
        background = "e1e2e7";
        selection-foreground = "3760bf";
        selection-background = "b6bfe2";

        regular0 = "b4b5b9";
        regular1 = "f52a65";
        regular2 = "587539";
        regular3 = "8c6c3e";
        regular4 = "2e7de9";
        regular5 = "9854f1";
        regular6 = "007197";
        regular7 = "6172b0";

        bright0 = "a1a6c5";
        bright1 = "f52a65";
        bright2 = "587539";
        bright3 = "8c6c3e";
        bright4 = "2e7de9";
        bright5 = "9854f1";
        bright6 = "007197";
        bright7 = "3760bf";
      };
    };
  };
}
