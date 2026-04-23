{
  config,
  pkgs,
  lib,
  inputs,
  hostName,
  ...
}:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    package = unstable-pkgs.pipewire;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    wireplumber.enable = true;
    wireplumber.package = unstable-pkgs.wireplumber;

    # The Jabra SPEAK 510 (USB audio) xruns continuously at the default
    # 1024-sample quantum (21ms @ 48kHz), showing up as nonstop
    # `snd_pcm_avail after recover: Broken pipe` and audible stuttering.
    # Raise the buffer to 2048 (43ms) to give USB audio more headroom
    # without making latency noticeable on calls.
    extraConfig.pipewire."99-workstation-quantum" = lib.mkIf (hostName == "workstation") {
      "context.properties" = {
        "default.clock.quantum" = 2048;
        "default.clock.min-quantum" = 1024;
        "default.clock.max-quantum" = 4096;
      };
    };
  };
  services.pulseaudio.enable = false;

  # Pin card profiles on the workstation so audio survives a wireplumber
  # state wipe. The Jabra SPEAK 510's IEC958 profile is unusable on this
  # hardware (endless snd_pcm_avail: Broken pipe), and the onboard ALC4082
  # must be on HiFi to expose its Speaker/Headphones/S/PDIF sinks.
  systemd.user.services.workstation-audio-profiles = lib.mkIf (hostName == "workstation") {
    description = "Pin ASRock X870E Taichi audio card profiles";
    wantedBy = [
      "pipewire-pulse.service"
      "wireplumber.service"
    ];
    after = [
      "pipewire-pulse.service"
      "wireplumber.service"
    ];
    # PartOf ties lifecycle to wireplumber/pipewire-pulse so that when either
    # restarts (which wipes card profiles back to wireplumber's defaults) this
    # service is restarted too and re-pins the correct profiles.
    partOf = [
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
