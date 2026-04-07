# test change
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  # Application launcher with Kanagawa theming

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
      term = "alacritty msg create-window";
      sort_order = "alphabetical";
    };

    style = ''
      window {
        margin: 0px;
        border: 2px solid #dcd7ba;
        background-color: rgba(31, 31, 40, 0.95);
        border-radius: 8px;
      }

      #input {
        margin: 8px;
        padding: 8px;
        border: none;
        color: #dcd7ba;
        font-size: 14px;
        background-color: rgba(84, 84, 109, 0.3);
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
        color: #dcd7ba;
        border-radius: 6px;
      }

      #entry:selected {
        background-color: rgba(220, 215, 186, 0.2);
        color: #dcd7ba;
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
