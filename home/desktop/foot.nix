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
    # DMS's generated foot palette currently uses section names foot does
    # not accept, so keep the Nix-managed palette in charge.
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

  # In DMS mode, write foot.ini directly so we can keep the same settings
  # without including DMS's invalid foot palette.
  xdg.configFile."foot/foot.ini" = lib.mkIf useDms {
    text = ''
      [main]
      font=CaskaydiaMono Nerd Font:size=11
      font-bold=CaskaydiaMono Nerd Font:style=Bold:size=11
      font-italic=CaskaydiaMono Nerd Font:style=Italic:size=11
      dpi-aware=no
      pad=5x5
      shell=fish

      [colors]
      alpha=0.98
      foreground=dcd7ba
      background=1f1f28
      regular0=090618
      regular1=c34043
      regular2=76946a
      regular3=c0a36e
      regular4=7e9cd8
      regular5=957fb8
      regular6=6a9589
      regular7=c8c093
      bright0=727169
      bright1=e82424
      bright2=98bb6c
      bright3=e6c384
      bright4=7fb4ca
      bright5=938aa9
      bright6=7aa89f
      bright7=dcd7ba
    '';
  };
}
