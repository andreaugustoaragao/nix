{
  hostName,
  lib,
  pkgs,
  unstable-pkgs,
  ...
}:
let
  media = "/srv/immich";
in
{
  config = lib.mkIf (hostName == "tala") {
    fileSystems."${media}" = {
      # The dedicated Immich export is maui's NFSv4 root (fsid=0).
      device = "192.168.40.3:/";
      fsType = "nfs";
      options = [
        "vers=4.2"
        "hard"
        "nosuid"
        "nodev"
        "noexec"
        "nofail"
        "x-systemd.mount-timeout=30s"
      ];
    };

    services.immich = {
      enable = true;
      package = unstable-pkgs.immich;
      host = "192.168.40.10";
      mediaLocation = media;
      accelerationDevices = [ "/dev/dri/renderD128" ];
      machine-learning.environment.XDG_RUNTIME_DIR = "/run/immich-machine-learning";
      settings = {
        server.externalDomain = "https://photos.faragao.net";
        ffmpeg.accel = "vaapi";
      };
    };
    hardware.graphics = {
      enable = true;
      extraPackages = [ pkgs.intel-media-driver ];
    };

    # AUTH_SYS on maui uses the same numeric service identity.
    users.users.immich = {
      uid = 22830;
      extraGroups = [ "render" ];
    };
    users.groups.immich.gid = 22830;
    # The export owner and mode are set on maui. Client root is squashed.
    systemd.tmpfiles.settings.immich = lib.mkForce { };
    systemd.services.immich-machine-learning.serviceConfig = {
      RuntimeDirectory = "immich-machine-learning";
      RuntimeDirectoryMode = "0700";
    };
    systemd.services.immich-server = {
      bindsTo = [ "srv-immich.mount" ];
      after = [
        "srv-immich.mount"
        "redis-immich.service"
      ];
      requires = [ "redis-immich.service" ];
      unitConfig.AssertPathIsMountPoint = media;
    };

    networking.firewall.extraCommands = ''
      iptables -w -I nixos-fw 1 -d 192.168.40.10 -p tcp --dport 2283 ! -s 192.168.40.3 -j nixos-fw-refuse
      iptables -w -A nixos-fw -d 192.168.40.10 -s 192.168.40.3 -p tcp --dport 2283 -j nixos-fw-accept
    '';
  };
}
