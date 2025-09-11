{ config, pkgs, lib, inputs, ... }:

{
  # Font packages used across desktop and CLI
  home.packages = with pkgs; [
    jetbrains-mono
    liberation_ttf
    noto-fonts-emoji
    font-awesome
    noto-fonts-color-emoji
  ] ++ (with pkgs.nerd-fonts; [
    cascadia-code
    caskaydia-mono
    jetbrains-mono
    symbols-only
  ]);

  # System-wide fontconfig defaults
  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      monospace = [ "CaskaydiaMono Nerd Font" ];
    };
  };

  # Niri-specific Fontconfig: prefer CaskaydiaMono Nerd Font for titles/labels
  xdg.configFile."fontconfig/conf.d/50-niri-fonts.conf".text = ''
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
} 