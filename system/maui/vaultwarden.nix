{ config, ... }:
let
  cloudflare = import ./cloudflare-ips.nix;
in
{
  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://vw.faragao.net";
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = "8000";
      SIGNUPS_ALLOWED = false;
      #SIGNUPS_DOMAINS_WHITELIST = "faragao.net";
      INVITATIONS_ALLOWED = false;
      PUSH_ENABLED = true;
      #DATA_FOLDER = "/data/services/vw/data";
    };
    environmentFile = config.sops.secrets.vaultwarden_env.path;
    backupDir = "/data/services/vw/backup";
  };

  systemd.services.vaultwarden = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };

  services.nginx.virtualHosts."vw.faragao.net" = {
    forceSSL = true;
    useACMEHost = "faragao.net";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8000";
      recommendedProxySettings = true;
      proxyWebsockets = true;
      extraConfig = ''
        allow 127.0.0.1;
        allow 192.168.10.0/24;
        allow 192.168.20.0/24;
        allow 192.168.50.0/24;
        allow 192.168.60.0/24;
        # Cloudflare IPv4 ranges (https://www.cloudflare.com/ips-v4)
        ${cloudflare.nginxAllowBlock}
        deny all;
      '';
    };
  };
}
