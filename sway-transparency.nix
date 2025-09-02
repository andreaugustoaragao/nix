{ pkgs }:

pkgs.writeShellScriptBin "sway-transparency" ''
  #!/usr/bin/env bash
  
  # Dynamic transparency script for Sway
  # This script monitors focus changes and adjusts window opacity
  
  FOCUSED_OPACITY=0.95
  UNFOCUSED_OPACITY=0.85
  MEDIA_OPACITY=1.0
  
  # Media applications that should remain opaque
  MEDIA_APPS="zoom|vlc|mpv|youtube|netflix"
  
  # Function to set window opacity
  set_opacity() {
    local window_id="$1"
    local opacity="$2"
    
    # Check if it's a media application
    app_id=$(swaymsg -t get_tree | jq -r ".. | select(.focused? == true) | .app_id // empty")
    window_class=$(swaymsg -t get_tree | jq -r ".. | select(.focused? == true) | .window_properties.class // empty")
    
    if [[ "$app_id" =~ $MEDIA_APPS ]] || [[ "$window_class" =~ $MEDIA_APPS ]]; then
        opacity=$MEDIA_OPACITY
    fi
    
    swaymsg "[con_id=$window_id] opacity $opacity" >/dev/null 2>&1
  }
  
  # Set initial opacity for all windows
  swaymsg -t get_tree | jq -r '.. | select(.type? == "con" and .app_id?) | .id' | while read -r window_id; do
    set_opacity "$window_id" "$UNFOCUSED_OPACITY"
  done
  
  # Monitor focus changes
  swaymsg -t subscribe -m '["window"]' | while read -r event; do
    change=$(echo "$event" | jq -r '.change')
    container_id=$(echo "$event" | jq -r '.container.id')
    
    case "$change" in
      "focus")
        # Set focused window to higher opacity
        set_opacity "$container_id" "$FOCUSED_OPACITY"
        
        # Set all other windows to lower opacity
        swaymsg -t get_tree | jq -r ".. | select(.type? == \"con\" and .app_id? and .id != $container_id) | .id" | while read -r other_id; do
          set_opacity "$other_id" "$UNFOCUSED_OPACITY"
        done
        ;;
    esac
  done
''