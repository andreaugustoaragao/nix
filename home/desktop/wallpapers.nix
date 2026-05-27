{ pkgs, ... }:

let
  wallpapers = pkgs.runCommand "wallpapers" { } ''
    mkdir -p $out/share/wallpapers
    cp ${../../assets/wallpapers/kanagawa.jpg}             $out/share/wallpapers/kanagawa.jpg
    cp ${../../assets/wallpapers/fuji-day.jpg}             $out/share/wallpapers/fuji-day.jpg
    cp ${../../assets/wallpapers/fuji-pagoda-sunset.jpg}   $out/share/wallpapers/fuji-pagoda-sunset.jpg
    cp ${../../assets/wallpapers/blue-jays.png}            $out/share/wallpapers/blue-jays.png
    cp ${../../assets/wallpapers/atake-sudden-shower.jpg}  $out/share/wallpapers/atake-sudden-shower.jpg
    cp ${../../assets/wallpapers/kameido-plum-park.jpg}    $out/share/wallpapers/kameido-plum-park.jpg
    cp ${../../assets/wallpapers/avaya-hq.png}             $out/share/wallpapers/avaya-hq.png
  '';

  # Per-output wallpapers (see home/desktop/niri.nix: DP-2 is physically
  # left/portrait, DP-1 is right/landscape). quickshell.nix references
  # dp1Wallpapers for the DP-1 connector.
  dp1Wallpapers = {
    dark = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
    light = "${wallpapers}/share/wallpapers/blue-jays.png";
  };
in
{
  home.packages = [ wallpapers ];

  home.sessionVariables = {
    KANAGAWA_WALLPAPER = "${wallpapers}/share/wallpapers/kanagawa.jpg";
    FUJI_DAY_WALLPAPER = "${wallpapers}/share/wallpapers/fuji-day.jpg";
    FUJI_PAGODA_SUNSET_WALLPAPER = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
  };

  # Expose the derivation for other modules (DMS) to reference.
  _module.args.wallpapers = wallpapers;
  _module.args.dp1Wallpapers = dp1Wallpapers;
}
