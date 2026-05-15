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
    # DMS's shipped foot template only emits a `[colors-dark]` section
    # (with mode-aware colors), so in light mode foot falls back to its
    # compiled defaults. We render our own colors file via matugen (see
    # home/desktop/matugen.nix) and `include` it from foot.ini below.
    settings = lib.mkIf (!useDms) {
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

  # In DMS mode write foot.ini ourselves: pull colors from the matugen-
  # rendered include (mode-aware via `.default.` accessor), keep all
  # non-color settings here.
  xdg.configFile."foot/foot.ini" = lib.mkIf useDms {
    text = ''
      [main]
      font=CaskaydiaMono Nerd Font:size=11
      font-bold=CaskaydiaMono Nerd Font:style=Bold:size=11
      font-italic=CaskaydiaMono Nerd Font:style=Italic:size=11
      dpi-aware=no
      pad=5x5
      shell=fish

      include=~/.config/foot/colors-matugen.ini
    '';
  };
}
