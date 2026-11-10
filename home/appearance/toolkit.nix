{ lib, appearance }:
let
  mkMode =
    mode:
    let
      c = appearance.${mode};
      accent = c.green;
      onAccent = c.base;
      colors = {
        theme_bg_color = c.base;
        theme_base_color = c.base;
        theme_fg_color = c.text;
        theme_text_color = c.text;
        theme_selected_bg_color = accent;
        theme_selected_fg_color = onAccent;
        theme_unfocused_bg_color = c.base;
        theme_unfocused_base_color = c.base;
        theme_unfocused_fg_color = c.subtext0;
        theme_unfocused_text_color = c.subtext0;
        theme_unfocused_selected_bg_color = c.surface1;
        theme_unfocused_selected_fg_color = c.text;
        insensitive_bg_color = c.surface0;
        insensitive_fg_color = c.overlay0;
        insensitive_base_color = c.base;
        borders = c.surface2;
        unfocused_borders = c.surface1;
        accent_color = accent;
        accent_bg_color = accent;
        accent_fg_color = onAccent;
        window_bg_color = c.base;
        window_fg_color = c.text;
        view_bg_color = c.base;
        view_fg_color = c.text;
        headerbar_bg_color = c.mantle;
        headerbar_fg_color = c.text;
        headerbar_backdrop_color = c.base;
        card_bg_color = c.surface0;
        card_fg_color = c.text;
        dialog_bg_color = c.base;
        dialog_fg_color = c.text;
        popover_bg_color = c.surface0;
        popover_fg_color = c.text;
        sidebar_bg_color = c.mantle;
        sidebar_fg_color = c.text;
        sidebar_backdrop_color = c.base;
        sidebar_border_color = c.surface1;
        secondary_sidebar_bg_color = c.surface0;
        secondary_sidebar_fg_color = c.text;
        overview_bg_color = c.mantle;
        overview_fg_color = c.text;
        destructive_color = c.red;
        destructive_bg_color = c.red;
        destructive_fg_color = c.base;
        error_color = c.red;
        error_bg_color = c.red;
        error_fg_color = c.base;
        warning_color = c.yellow;
        warning_bg_color = c.yellow;
        warning_fg_color = c.base;
        success_color = c.green;
        success_bg_color = c.green;
        success_fg_color = c.base;
      };
      gtk3 =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: value: "@define-color ${name} ${value};") colors
        )
        + "\n";
      gtk4 =
        gtk3
        + "\n:root {\n"
        + lib.concatStringsSep "\n" (
          lib.mapAttrsToList
            (
              name: value:
              "  --${lib.replaceStrings [ "_" ] [ "-" ] (lib.removeSuffix "_color" name)}-color: ${value};"
            )
            (
              lib.filterAttrs (
                name: _: !(lib.hasPrefix "theme_" name) && name != "borders" && name != "unfocused_borders"
              ) colors
            )
        )
        + "\n}\n";
      qtColors = disabled: [
        (if disabled then c.overlay0 else c.text) # WindowText
        c.surface0 # Button
        c.surface2 # Light
        c.surface1 # Midlight
        c.mantle # Dark
        c.surface1 # Mid
        (if disabled then c.overlay0 else c.text) # Text
        c.base # BrightText
        (if disabled then c.overlay0 else c.text) # ButtonText
        c.base # Base
        c.base # Window
        c.crust # Shadow
        (if disabled then c.surface1 else accent) # Highlight
        (if disabled then c.overlay0 else onAccent) # HighlightedText
        c.blue # Link
        c.mauve # LinkVisited
        c.surface0 # AlternateBase
        c.base # NoRole
        c.surface0 # ToolTipBase
        c.text # ToolTipText
        c.overlay0 # PlaceholderText
        accent # Accent (Qt 6.6+)
      ];
      qt = ''
        [ColorScheme]
        active_colors=${lib.concatStringsSep ", " (qtColors false)}
        inactive_colors=${lib.concatStringsSep ", " (qtColors false)}
        disabled_colors=${lib.concatStringsSep ", " (qtColors true)}
      '';
      rgb =
        color:
        lib.concatStringsSep "," (
          map
            (offset: toString (lib.fromHexString (builtins.substring offset 2 (lib.removePrefix "#" color))))
            [
              0
              2
              4
            ]
        );
      kdeSection = background: {
        BackgroundNormal = rgb background;
        BackgroundAlternate = rgb c.surface0;
        ForegroundNormal = rgb c.text;
        ForegroundInactive = rgb c.overlay0;
        ForegroundActive = rgb accent;
        ForegroundLink = rgb c.blue;
        ForegroundVisited = rgb c.mauve;
        ForegroundNegative = rgb c.red;
        ForegroundNeutral = rgb c.yellow;
        ForegroundPositive = rgb c.green;
        DecorationFocus = rgb accent;
        DecorationHover = rgb c.blue;
      };
      kde = {
        General.ColorScheme = if mode == "dark" then "GruvboxDark" else "GruvboxLight";
        "Colors:Window" = kdeSection c.base;
        "Colors:View" = kdeSection c.base;
        "Colors:Button" = kdeSection c.surface0;
        "Colors:Tooltip" = kdeSection c.surface0;
        "Colors:Complementary" = kdeSection c.mantle;
        "Colors:Header" = kdeSection c.mantle;
        "Colors:Selection" = (kdeSection accent) // {
          ForegroundNormal = rgb onAccent;
        };
        Icons.Theme = if mode == "dark" then "Papirus-Dark" else "Papirus-Light";
      };
    in
    {
      inherit
        gtk3
        gtk4
        qt
        kde
        ;
    };
in
lib.genAttrs [ "dark" "light" ] mkMode
