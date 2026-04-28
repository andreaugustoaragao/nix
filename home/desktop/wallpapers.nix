{ pkgs, ... }:

let
  wallpapers = pkgs.runCommand "wallpapers" { } ''
    mkdir -p $out/share/wallpapers
    cp ${../../assets/wallpapers/kanagawa.jpg}            $out/share/wallpapers/kanagawa.jpg
    cp ${../../assets/wallpapers/fuji-day.jpg}            $out/share/wallpapers/fuji-day.jpg
    cp ${../../assets/wallpapers/fuji-pagoda-sunset.jpg}  $out/share/wallpapers/fuji-pagoda-sunset.jpg
  '';
in
{
  home.packages = [ wallpapers ];

  home.sessionVariables = {
    KANAGAWA_WALLPAPER          = "${wallpapers}/share/wallpapers/kanagawa.jpg";
    FUJI_DAY_WALLPAPER          = "${wallpapers}/share/wallpapers/fuji-day.jpg";
    FUJI_PAGODA_SUNSET_WALLPAPER = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
  };

  # Expose the derivation for other modules (DMS) to reference.
  _module.args.wallpapers = wallpapers;
}
