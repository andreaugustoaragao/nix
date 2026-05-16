{
  config,
  pkgs,
  lib,
  bluetooth ? false,
  ...
}:

{
  config = lib.mkIf bluetooth {
    hardware = {
      # Enable Bluetooth hardware
      bluetooth = {
        enable = true;
        powerOnBoot = true;
      };

      firmware = [ pkgs.broadcom-bt-firmware ];
    };

    services = {
      # Enable Bluetooth service
      blueman.enable = true;

      # Enable PulseAudio/PipeWire Bluetooth support
      pulseaudio.package = lib.mkIf config.services.pulseaudio.enable (
        pkgs.pulseaudio.override { bluetoothSupport = true; }
      );

      # For PipeWire (which is more common in modern setups)
      pipewire.wireplumber.extraConfig = lib.mkIf config.services.pipewire.enable {
        "10-bluez" = {
          "monitor.bluez.properties" = {
            "bluez5.enable-sbc-xq" = true;
            "bluez5.enable-msbc" = true;
            "bluez5.enable-hw-volume" = true;
            "bluez5.roles" = [
              "a2dp_sink"
              "a2dp_source"
              "hsp_hs"
              "hsp_ag"
              "hfp_hf"
              "hfp_ag"
            ];
          };
        };
      };
    };

    # Add Bluetooth packages for GUI management
    environment.systemPackages = with pkgs; [
      bluez
      bluez-tools
      blueman
    ];
  };
}
