{ config, pkgs, lib, inputs, ... }:

{
  # Ensure wallpaper directory exists
  home.file.".local/share/wallpapers/.keep".text = "";

  # Create a simple gradient wallpaper if Kanagawa wallpaper isn't available
  home.activation.createWallpaper = lib.hm.dag.entryAfter ["writeBoundary"] ''
    WALLPAPER_DIR="${config.home.homeDirectory}/.local/share/wallpapers"
    WALLPAPER_FILE="$WALLPAPER_DIR/1-kanagawa.jpg"
    
    # Create wallpaper directory
    mkdir -p "$WALLPAPER_DIR"
    
    # If wallpaper doesn't exist, create a simple solid color one using ImageMagick (if available)
    if [[ ! -f "$WALLPAPER_FILE" ]]; then
      echo "Creating default Kanagawa-themed wallpaper..."
      if command -v ${pkgs.imagemagick}/bin/convert >/dev/null 2>&1; then
        # Create a simple gradient wallpaper with Kanagawa colors
        ${pkgs.imagemagick}/bin/convert -size 1920x1080 \
          gradient:"#1f1f28-#2a2a37" \
          "$WALLPAPER_FILE"
        echo "Created default wallpaper at $WALLPAPER_FILE"
      else
        echo "ImageMagick not available. Please manually add a wallpaper at $WALLPAPER_FILE"
        $DRY_RUN_CMD touch "$WALLPAPER_FILE"
      fi
    fi
  '';
} 