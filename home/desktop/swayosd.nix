{
  pkgs,
  ...
}:

{
  # Install SwayOSD package
  home.packages = with pkgs; [
    swayosd
  ];

  # SwayOSD configuration (Omarchy style with Catppuccin theme)
  xdg.configFile."swayosd/config.toml".text = ''
    [server]
    show_percentage = true
    max_volume = 100
    style = "./style.css"
  '';

  xdg.configFile."swayosd/style.css".text = ''
    /* Catppuccin Mocha colors for SwayOSD */
    @define-color background-color #1e1e2e;
    @define-color border-color #cdd6f4;
    @define-color label #cdd6f4;
    @define-color image #cdd6f4;
    @define-color progress #cdd6f4;

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
      background-color: rgba(205, 214, 244, 0.2);
    }

    progressbar progress {
      background-color: @progress;
    }
  '';
}
