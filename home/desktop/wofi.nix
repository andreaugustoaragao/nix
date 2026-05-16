# test change
_:

{
  # Application launcher with Catppuccin Mocha theming

  programs.wofi = {
    enable = true;
    settings = {
      width = 600;
      height = 400;
      location = "center";
      show = "drun";
      prompt = "Search...";
      filter_rate = 100;
      allow_markup = true;
      no_actions = true;
      halign = "fill";
      orientation = "vertical";
      content_halign = "fill";
      insensitive = true;
      allow_images = true;
      image_size = 24;
      hide_scroll = true;
      print_command = true;
      layer = "overlay";
      term = "ghostty";
      sort_order = "alphabetical";
    };

    style = ''
      window {
        margin: 0px;
        border: 2px solid #cdd6f4;
        background-color: rgba(30, 30, 46, 0.95);
        border-radius: 8px;
      }

      #input {
        margin: 8px;
        padding: 8px;
        border: none;
        color: #cdd6f4;
        font-size: 14px;
        background-color: rgba(88, 91, 112, 0.3);
        border-radius: 6px;
        font-weight: 600;
      }

      #inner-box {
        margin: 8px;
        padding: 0px;
        border: none;
        background-color: transparent;
      }

      #outer-box {
        margin: 0px;
        padding: 0px;
        border: none;
        background-color: transparent;
      }

      #scroll {
        margin: 0px;
        border: none;
        background-color: transparent;
      }

      #entry {
        padding: 8px;
        margin: 2px;
        border: none;
        background-color: transparent;
        color: #cdd6f4;
        border-radius: 6px;
      }

      #entry:selected {
        background-color: rgba(205, 214, 244, 0.2);
        color: #cdd6f4;
        font-weight: 600;
        border: none;
        outline: none;
        box-shadow: none;
      }

      #entry img {
        margin-right: 16px;
        border-radius: 6px;
        padding: 4px;
      }


      #entry #text {
        margin-left: 8px;
      }

    '';
  };
}
