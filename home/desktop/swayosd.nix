{ config, pkgs, lib, inputs, ... }:

{
  # SwayOSD configuration (Omarchy style with Kanagawa theme)
  xdg.configFile."swayosd/config.toml".text = ''
    [server]
    show_percentage = true
    max_volume = 100
    style = "./style.css"
  '';

  xdg.configFile."swayosd/style.css".text = ''
    /* Kanagawa colors for SwayOSD */
    @define-color background-color #1f1f28;
    @define-color border-color #dcd7ba;
    @define-color label #dcd7ba;
    @define-color image #dcd7ba;
    @define-color progress #dcd7ba;

    window {
      border-radius: 0;
      opacity: 0.97;
      background: @background-color;
    }

    image {
      color: @image;
    }

    label {
      color: @label;
    }

    progressbar {
      color: @progress;
    }

    progressbar trough {
      background-color: rgba(220, 215, 186, 0.2);
    }

    progressbar progress {
      background-color: @progress;
    }
  '';
}