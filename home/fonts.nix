{ pkgs, lib, ... }:

let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
in
{
  # Font packages used across desktop and CLI. On Darwin home-manager
  # links these into ~/Library/Fonts automatically; on Linux fontconfig
  # picks them up from the nix profile.
  home.packages =
    with pkgs;
    [
      jetbrains-mono
      liberation_ttf
      font-awesome
      noto-fonts-color-emoji
      cantarell-fonts
    ]
    ++ (with pkgs.nerd-fonts; [
      cascadia-code
      caskaydia-mono
      jetbrains-mono
      symbols-only
    ]);

  # fonts.fontconfig (HM option) is Linux-only — fontconfig itself
  # isn't part of the macOS rendering stack.
  fonts.fontconfig = lib.mkIf isLinux {
    enable = true;
    defaultFonts = {
      monospace = [ "CaskaydiaMono Nerd Font" ];
    };
  };

  # Niri-specific fontconfig — Linux + Wayland only.
  xdg.configFile."fontconfig/conf.d/50-niri-fonts.conf" = lib.mkIf isLinux {
    text = ''
      <?xml version='1.0'?>
      <!DOCTYPE fontconfig SYSTEM 'urn:fontconfig:fonts.dtd'>
      <fontconfig>
        <!-- Prefer CaskaydiaMono Nerd Font when the requesting program is niri -->
        <match target="pattern">
          <test name="prgname" compare="eq">
            <string>niri</string>
          </test>
          <!-- For monospace, ensure CaskaydiaMono is first -->
          <test name="family" compare="eq">
            <string>monospace</string>
          </test>
          <edit mode="prepend" name="family">
            <string>CaskaydiaMono Nerd Font</string>
          </edit>
        </match>

        <!-- Also gently prefer CaskaydiaMono for generic UI text in niri -->
        <match target="pattern">
          <test name="prgname" compare="eq">
            <string>niri</string>
          </test>
          <edit mode="prepend" name="family">
            <string>CaskaydiaMono Nerd Font</string>
          </edit>
        </match>
      </fontconfig>
    '';
  };
}
