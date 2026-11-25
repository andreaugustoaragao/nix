{ pkgs, ... }:

{
  fonts.packages = with pkgs; [
    geist-font
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    yaru-theme
  ];
}
