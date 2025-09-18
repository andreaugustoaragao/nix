{ config, pkgs, lib, bluetooth ? false, ... }:

{
  config = lib.mkIf bluetooth {
    # Enable Bluetooth hardware
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          Enable = "Source,Sink,Media,Socket";
          Experimental = true;
        };
      };
    };

    # Enable Bluetooth service
    services.blueman.enable = true;

    # Add Bluetooth packages for GUI management
    environment.systemPackages = with pkgs; [
      bluez
      bluez-tools
      blueman
      broadcom-bt-firmware
    ];

    # Enable PulseAudio/PipeWire Bluetooth support
    services.pulseaudio.package = lib.mkIf config.services.pulseaudio.enable 
      (pkgs.pulseaudio.override { bluetoothSupport = true; });

    # For PipeWire (which is more common in modern setups)
    services.pipewire.wireplumber.extraConfig = lib.mkIf config.services.pipewire.enable {
      "10-bluez" = {
        "monitor.bluez.properties" = {
          "bluez5.enable-sbc-xq" = true;
          "bluez5.enable-msbc" = true;
          "bluez5.enable-hw-volume" = true;
          "bluez5.roles" = [ "hsp_hs" "hsp_ag" "hfp_hf" "hfp_ag" ];
        };
      };
    };
  };
}