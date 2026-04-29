{ pkgs, lib, useDms ? false, ... }:
{
  # Papirus provides icons for nearly every Linux desktop app — without
  # it fuzzel silently shows entries with no icon.
  home.packages = [ pkgs.papirus-icon-theme ];

  programs.fuzzel = {
    enable = true;
    # fuzzel has no `include` directive — when DMS is on, matugen writes
    # the entire fuzzel.ini, so let it own the file by skipping settings.
    settings = lib.mkIf (!useDms) {
      main = {
        prompt = "";
        layer = "overlay";
        width = 50;
        lines = 12;
        horizontal-pad = 16;
        vertical-pad = 12;
        inner-pad = 8;
        line-height = 22;
        icon-theme = "Papirus-Dark";
        terminal = "ghostty -e";
        fields = "name,generic,comment,categories,filename,keywords";
      };

      colors = {
        background = "1f1f28f2";
        text = "dcd7baff";
        match = "7e9cd8ff";
        selection = "dcd7ba33";
        selection-text = "dcd7baff";
        selection-match = "7e9cd8ff";
        border = "dcd7baff";
      };

      border = {
        width = 2;
        radius = 8;
      };
    };
  };
}
