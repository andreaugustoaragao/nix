{
  config,
  pkgs,
  lib,
  personalOnly,
  hostName,
  isVm ? false,
  ...
}:

let
  enableThunar = hostName != "prl-dev-vm";
  term = import ./default-terminal.nix { inherit isVm; };
  bookmarkDefaults = pkgs.writeText "gtk-bookmarks-defaults" ''
    file://${config.home.homeDirectory}/downloads downloads
    ${lib.optionalString (!personalOnly) ''
      file://${config.home.homeDirectory}/projects/work work
    ''}
    file://${config.home.homeDirectory}/projects/personal personal
    ${lib.optionalString (!personalOnly) ''
      file://${config.home.homeDirectory}/projects/work/notes notes
    ''}
    file://${config.home.homeDirectory}/pictures/screenshots screenshots
    ${lib.optionalString (!personalOnly) ''
      file://${config.home.homeDirectory}/projects/work/infinity-core infinity-core
    ''}
  '';
in
{
  # Thunar and thumbnailing packages
  home.packages = lib.optionals enableThunar (
    with pkgs;
    [
      thunar
      tumbler # Thumbnail service for Thunar
      ffmpegthumbnailer # Video thumbnails
      poppler-utils # PDF thumbnails
    ]
  );

  home.activation.initializeGtkBookmarks =
    lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ]
      ''
        bookmarks_dir=${lib.escapeShellArg "${config.xdg.configHome}/gtk-3.0"}
        bookmarks_path="$bookmarks_dir/bookmarks"
        if [[ -L "$bookmarks_path" || ! -e "$bookmarks_path" ]]; then
          if [[ -n "''${DRY_RUN_CMD:-}" ]]; then
            echo "Initialize writable GTK bookmarks: $bookmarks_path"
          else
            mkdir -p "$bookmarks_dir"
            bookmarks_source=${bookmarkDefaults}
            if [[ -L "$bookmarks_path" ]]; then
              bookmarks_source="$bookmarks_path"
            fi
            bookmarks_tmp=$(mktemp "$bookmarks_dir/.bookmarks.XXXXXX")
            cp -L -- "$bookmarks_source" "$bookmarks_tmp"
            chmod 600 "$bookmarks_tmp"
            mv -Tf -- "$bookmarks_tmp" "$bookmarks_path"
          fi
        fi
      '';

  # Thunar file manager configuration via home-manager activation
  home.activation.configureThunar = lib.mkIf enableThunar (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # Create project directories if they don't exist
      ${lib.optionalString (!personalOnly) ''
        mkdir -p "${config.home.homeDirectory}/projects/work"
      ''}
      mkdir -p "${config.home.homeDirectory}/projects/personal"
      echo "Created project directories"

      # Configure Thunar via xfconf-query during home-manager activation
      if command -v xfconf-query >/dev/null 2>&1; then
        echo "Configuring Thunar via xfconf..."

        # Set default view to details (list view)
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /default-view -s "ThunarDetailsView" --create --type string
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /last-view -s "ThunarDetailsView" --create --type string

        # Enable working directory for terminal commands
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /misc-exec-shell-command-working-directory -s true --create --type bool

        # Enable thumbnails
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /misc-show-thumbnails -s true --create --type bool

        # Show toolbar and statusbar
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /last-toolbar-visible -s true --create --type bool
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /last-statusbar-visible -s true --create --type bool

        # Set folders first in sorting
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /misc-folders-first -s true --create --type bool

        # Set reasonable window size
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /last-window-width -s 900 --create --type int
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /last-window-height -s 600 --create --type int

        # Column widths for details view (name, size, type, modified)
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /last-details-view-column-widths -s "250,100,100,150" --create --type string

        # Show side panel with shortcuts
        $DRY_RUN_CMD ${pkgs.xfconf}/bin/xfconf-query -c thunar -p /last-side-pane -s "ThunarShortcutsPane" --create --type string

        echo "Thunar configuration completed"
      else
        echo "xfconf-query not available, skipping Thunar configuration"
      fi
    ''
  );

  # Thunar custom actions. Terminal selection follows
  # ./default-terminal.nix so VMs get kitty.
  xdg.configFile."Thunar/uca.xml" = lib.mkIf enableThunar {
    text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <actions>
      <action>
        <icon>utilities-terminal</icon>
        <name>Open Terminal Here</name>
        <unique-id>1409659827532001-1</unique-id>
        <command>${term.openInDirCommand}</command>
        <description>Open a terminal in the current directory</description>
        <patterns>*</patterns>
        <startup-notify/>
        <directories/>
      </action>
      </actions>
    '';
  };
}
