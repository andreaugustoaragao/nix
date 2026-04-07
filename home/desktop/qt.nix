{ config, pkgs, lib, inputs, ... }:

{
  qt = {
    enable = true;
    platformTheme.name = "adwaita";
    style.name = "adwaita-dark";
  };

  # Ensure Adwaita Qt style plugins are available for Qt5/Qt6
  home.packages = [
    pkgs.adwaita-qt
    pkgs.adwaita-qt6
  ];
} 