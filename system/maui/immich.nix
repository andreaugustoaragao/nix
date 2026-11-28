{ pkgs, ... }:
let
  media = "/data/services/immich";
in
{
  users.groups.immich.gid = 22830;
  users.users.immich = {
    uid = 22830;
    group = "immich";
    isSystemUser = true;
  };

  services.nfs = {
    server = {
      enable = true;
      hostName = "192.168.40.3";
      exports."${media}"."192.168.40.10" = [
        "rw"
        "sync"
        "root_squash"
        "subtree_check"
        "fsid=0"
        "mountpoint=/data"
      ];
    };
    settings.nfsd = {
      vers3 = false;
      udp = false;
    };
  };

  # /data is a nofail mount. Create and export the directory only on the array.
  systemd.services.immich-media-directory = {
    bindsTo = [ "data.mount" ];
    after = [ "data.mount" ];
    unitConfig.AssertPathIsMountPoint = "/data";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/install -d -m 0700 -o immich -g immich ${media}";
    };
  };
  systemd.services.nfs-server = {
    requires = [ "immich-media-directory.service" ];
    bindsTo = [ "data.mount" ];
    after = [
      "data.mount"
      "immich-media-directory.service"
    ];
  };
  networking.firewall.extraCommands = ''
    iptables -w -A nixos-fw -d 192.168.40.3 -s 192.168.40.10 -p tcp --dport 2049 -j nixos-fw-accept
  '';

  services.nginx.virtualHosts."photos.faragao.net" = {
    forceSSL = true;
    useACMEHost = "faragao.net";
    locations."/" = {
      proxyPass = "http://192.168.40.10:2283";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        # Private pilot clients: Andre's workstation and his iPhone over WireGuard.
        allow 192.168.10.75;
        allow 192.168.60.2;
        deny all;
        client_max_body_size 50000m;
        proxy_request_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        send_timeout 600s;
      '';
    };
  };
}
