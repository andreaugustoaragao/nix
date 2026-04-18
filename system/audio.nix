{
  config,
  pkgs,
  lib,
  inputs,
  hostName,
  ...
}:

{
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    wireplumber.enable = true;
  };
  services.pulseaudio.enable = false;

  # Pin card profiles on the workstation so audio survives a wireplumber
  # state wipe. The Jabra SPEAK 510's IEC958 profile is unusable on this
  # hardware (endless snd_pcm_avail: Broken pipe), and the onboard ALC4082
  # must be on HiFi to expose its Speaker/Headphones/S/PDIF sinks.
  systemd.user.services.workstation-audio-profiles = lib.mkIf (hostName == "workstation") {
    description = "Pin ASRock X870E Taichi audio card profiles";
    wantedBy = [ "pipewire-pulse.service" ];
    after = [
      "pipewire-pulse.service"
      "wireplumber.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "workstation-audio-profiles" ''
        for _ in $(seq 1 15); do
          if ${pkgs.pulseaudio}/bin/pactl info >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        ${pkgs.pulseaudio}/bin/pactl set-card-profile \
          alsa_card.usb-0b0e_Jabra_SPEAK_510_USB_501AA57D071F020A00-00 \
          output:analog-stereo+input:mono-fallback || true
        ${pkgs.pulseaudio}/bin/pactl set-card-profile \
          alsa_card.usb-Generic_USB_Audio-00 HiFi || true
      '';
    };
  };
}
