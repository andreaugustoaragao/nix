{ config, ... }:
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
        allow 173.245.48.0/20;
        allow 103.21.244.0/22;
        allow 103.22.200.0/22;
        allow 103.31.4.0/22;
        allow 141.101.64.0/18;
        allow 108.162.192.0/18;
        allow 190.93.240.0/20;
        allow 188.114.96.0/20;
        allow 197.234.240.0/22;
        allow 198.41.128.0/17;
        allow 162.158.0.0/15;
        allow 104.16.0.0/13;
        allow 104.24.0.0/14;
        allow 172.64.0.0/13;
        allow 131.0.72.0/22;
        deny all;
      '';
    };
  };
}
