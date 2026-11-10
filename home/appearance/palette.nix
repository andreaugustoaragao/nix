{
  lib,
  colorScheme ? "catppuccin",
}:
let
  catppuccin = {
    dark = {
      rosewater = "#f5e0dc";
      flamingo = "#f2cdcd";
      pink = "#f5c2e7";
      mauve = "#cba6f7";
      red = "#f38ba8";
      maroon = "#eba0ac";
      peach = "#fab387";
      yellow = "#f9e2af";
      green = "#a6e3a1";
      teal = "#94e2d5";
      sky = "#89dceb";
      sapphire = "#74c7ec";
      blue = "#89b4fa";
      lavender = "#b4befe";
      text = "#cdd6f4";
      subtext1 = "#bac2de";
      subtext0 = "#a6adc8";
      overlay2 = "#9399b2";
      overlay1 = "#7f849c";
      overlay0 = "#6c7086";
      surface2 = "#585b70";
      surface1 = "#45475a";
      surface0 = "#313244";
      base = "#1e1e2e";
      mantle = "#181825";
      crust = "#11111b";
    };
    light = {
      rosewater = "#dc8a78";
      flamingo = "#dd7878";
      pink = "#ea76cb";
      mauve = "#8839ef";
      red = "#d20f39";
      maroon = "#e64553";
      peach = "#fe640b";
      yellow = "#df8e1d";
      green = "#40a02b";
      teal = "#179299";
      sky = "#04a5e5";
      sapphire = "#209fb5";
      blue = "#1e66f5";
      lavender = "#7287fd";
      text = "#4c4f69";
      subtext1 = "#5c5f77";
      subtext0 = "#6c6f85";
      overlay2 = "#7c7f93";
      overlay1 = "#8c8fa1";
      overlay0 = "#9ca0b0";
      surface2 = "#acb0be";
      surface1 = "#bcc0cc";
      surface0 = "#ccd0da";
      base = "#eff1f5";
      mantle = "#e6e9ef";
      crust = "#dce0e8";
    };
  };
  gruvbox = {
    dark = {
      rosewater = "#ebdbb2";
      flamingo = "#d65d0e";
      pink = "#d3869b";
      mauve = "#d3869b";
      red = "#fb4934";
      maroon = "#cc241d";
      peach = "#fe8019";
      yellow = "#fabd2f";
      green = "#b8bb26";
      teal = "#8ec07c";
      sky = "#83a598";
      sapphire = "#458588";
      blue = "#83a598";
      lavender = "#b16286";
      text = "#ebdbb2";
      subtext1 = "#d5c4a1";
      subtext0 = "#bdae93";
      overlay2 = "#bdae93";
      overlay1 = "#a89984";
      overlay0 = "#928374";
      surface2 = "#665c54";
      surface1 = "#504945";
      surface0 = "#3c3836";
      base = "#282828";
      mantle = "#1d2021";
      crust = "#1d2021";
    };
    light = {
      rosewater = "#3c3836";
      flamingo = "#af3a03";
      pink = "#8f3f71";
      mauve = "#8f3f71";
      red = "#9d0006";
      maroon = "#cc241d";
      peach = "#af3a03";
      yellow = "#b57614";
      green = "#79740e";
      teal = "#427b58";
      sky = "#076678";
      sapphire = "#458588";
      blue = "#076678";
      lavender = "#8f3f71";
      text = "#3c3836";
      subtext1 = "#504945";
      subtext0 = "#665c54";
      overlay2 = "#7c6f64";
      overlay1 = "#928374";
      overlay0 = "#a89984";
      surface2 = "#bdae93";
      surface1 = "#d5c4a1";
      surface0 = "#ebdbb2";
      base = "#fbf1c7";
      mantle = "#f2e5bc";
      crust = "#ebdbb2";
    };
  };
  isGruvbox = colorScheme == "gruvbox";
  selected = if isGruvbox then gruvbox else catppuccin;
  channels =
    color:
    map
      (offset: toString (lib.fromHexString (builtins.substring offset 2 (lib.removePrefix "#" color))))
      [
        0
        2
        4
      ];
  replacements =
    lib.concatMap
      (
        mode:
        lib.concatMap (
          key:
          let
            old = lib.removePrefix "#" catppuccin.${mode}.${key};
            new = lib.removePrefix "#" gruvbox.${mode}.${key};
          in
          [
            {
              from = old;
              to = new;
            }
            {
              from = lib.toUpper old;
              to = lib.toUpper new;
            }
          ]
          ++
            map
              (separator: {
                from = lib.concatStringsSep separator (channels catppuccin.${mode}.${key});
                to = lib.concatStringsSep separator (channels gruvbox.${mode}.${key});
              })
              [
                ","
                ", "
                ";"
              ]
        ) (builtins.attrNames catppuccin.${mode})
      )
      [
        "dark"
        "light"
      ];
  render =
    text:
    if isGruvbox then
      lib.replaceStrings (map (r: r.from) replacements) (map (r: r.to) replacements) text
    else
      text;
  mapColors =
    value:
    if builtins.isString value then
      render value
    else if builtins.isList value then
      map mapColors value
    else if builtins.isAttrs value && !lib.isDerivation value then
      lib.mapAttrs (_: mapColors) value
    else
      value;
in
assert builtins.elem colorScheme [
  "catppuccin"
  "gruvbox"
];
{
  name = colorScheme;
  inherit isGruvbox render mapColors;
  inherit (selected) dark light;
}
