{ config, pkgs, lib, inputs, ... }:

{
  # Thunar and thumbnailing packages
  home.packages = with pkgs; [
    xfce.thunar
    xfce.tumbler  # Thumbnail service for Thunar
    ffmpegthumbnailer  # Video thumbnails
    poppler-utils  # PDF thumbnails
  ];

  # GTK bookmarks for Thunar sidebar
  xdg.configFile."gtk-3.0/bookmarks".text = ''
    file://${config.home.homeDirectory}/projects projects
    file://${config.home.homeDirectory}/projects/work work
    file://${config.home.homeDirectory}/projects/personal personal
    file://${config.home.homeDirectory}/documents documents
    file://${config.home.homeDirectory}/downloads downloads
  '';

  # Thunar file manager configuration via home-manager activation
  home.activation.configureThunar = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Create project directories if they don't exist
    mkdir -p "${config.home.homeDirectory}/projects/work"
    mkdir -p "${config.home.homeDirectory}/projects/personal"
    echo "Created project directories"
    
    # Configure Thunar via xfconf-query during home-manager activation
    if command -v xfconf-query >/dev/null 2>&1; then
      echo "Configuring Thunar via xfconf..."
      
      # Set default view to details (list view)  
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /default-view -s "ThunarDetailsView" --create --type string
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-view -s "ThunarDetailsView" --create --type string
      
      # Enable working directory for terminal commands
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /misc-exec-shell-command-working-directory -s true --create --type bool
      
      # Enable thumbnails
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /misc-show-thumbnails -s true --create --type bool
      
      # Show toolbar and statusbar
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-toolbar-visible -s true --create --type bool
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-statusbar-visible -s true --create --type bool
      
      # Set folders first in sorting
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /misc-folders-first -s true --create --type bool
      
      # Set reasonable window size
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-window-width -s 900 --create --type int
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-window-height -s 600 --create --type int
      
      # Column widths for details view (name, size, type, modified)
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-details-view-column-widths -s "250,100,100,150" --create --type string
      
      # Show side panel with shortcuts
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-side-pane -s "ThunarShortcutsPane" --create --type string
      
      echo "Thunar configuration completed"
    else
      echo "xfconf-query not available, skipping Thunar configuration"
    fi
  '';

  # Thunar custom actions (set foot as terminal)
  xdg.configFile."Thunar/uca.xml".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <actions>
    <action>
      <icon>utilities-terminal</icon>
      <name>Open Terminal Here</name>
      <unique-id>1409659827532001-1</unique-id>
      <command>foot --working-directory=%f</command>
      <description>Open foot terminal in the current directory</description>
      <patterns>*</patterns>
      <startup-notify/>
      <directories/>
    </action>
    </actions>
  '';
} 