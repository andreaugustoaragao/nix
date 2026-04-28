{ ... }:
{
  programs.fuzzel = {
    enable = true;
    settings = {
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
        terminal = "alacritty msg create-window -e";
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
