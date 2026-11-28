{ config, ... }:
{
  services.nginx = {
    enable = true;
    resolver.ipv4 = true;
    resolver.ipv6 = false;
    resolver.addresses = [ "192.168.100.2" ];
    recommendedOptimisation = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    commonHttpConfig = ''
      ssl_certificate ${config.sops.secrets.nginx_origin_cert.path};
      ssl_certificate_key ${config.sops.secrets.nginx_origin_key.path};
    '';
    virtualHosts = {
      "faragao.net" = {
        serverAliases = [ "*.faragao.net" ];
        locations."/" = {
          return = "301 https://$host$request_uri";
        };
      };
      "auth.faragao.net" =
        let
          ingress = ''
            allow 127.0.0.1;
            allow 192.168.10.0/24;
            allow 192.168.20.0/24;
            allow 192.168.40.0/24;
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
          familySite = builtins.path {
            name = "faragao-family-site";
            path = ../../assets/family-chat;
          };
        in
        {
          forceSSL = true;
          useACMEHost = "faragao.net";
          locations."^~ /brand/" = {
            root = familySite;
            extraConfig = ingress;
          };
          locations."/" = {
            proxyPass = "http://192.168.40.10:9000";
            proxyWebsockets = true;
            recommendedProxySettings = true;
            extraConfig = ''
              proxy_buffers 8 16k;
              proxy_buffer_size 32k;
              ${ingress}
            '';
          };
        };
      "teka-web.faragao.net" = {
        forceSSL = true;
        useACMEHost = "faragao.net";
        locations."/" = {
          proxyPass = "https://192.168.40.4:5001";
          extraConfig = ''
            allow 127.0.0.1;
            allow 192.168.10.0/24;
            allow 192.168.20.0/24;
            allow 192.168.50.0/24;
            allow 192.168.60.0/24;
            deny all;
          '';
        };
      };
      "chief-tui-mgmt.faragao.net" = {
        forceSSL = true;
        useACMEHost = "faragao.net";
        locations."/" = {
          proxyPass = "https://192.168.100.3";
          proxyWebsockets = true;
          recommendedProxySettings = true;
          extraConfig = ''
            allow 127.0.0.1;
            allow 192.168.10.0/24;
            allow 192.168.50.0/24;
            allow 192.168.60.0/24;
            deny all;
          '';
        };
      };
      "wifi.faragao.net" = {
        forceSSL = true;
        useACMEHost = "faragao.net";
        locations."/" = {
          proxyPass = "https://192.168.100.53";
          proxyWebsockets = true;
          recommendedProxySettings = true;
          extraConfig = ''
            proxy_ssl_verify off;
            proxy_buffering off;
            proxy_read_timeout 300s;
            allow 127.0.0.1;
            allow 192.168.10.0/24;
            allow 192.168.50.0/24;
            allow 192.168.60.0/24;
            deny all;
          '';
        };
      };
      "printer.faragao.net" = {
        forceSSL = true;
        useACMEHost = "faragao.net";
        locations."/" = {
          proxyPass = "https://192.168.20.71";
          recommendedProxySettings = true;
          extraConfig = ''
            proxy_ssl_verify off;
            allow 127.0.0.1;
            allow 192.168.10.0/24;
            allow 192.168.20.0/24;
            allow 192.168.50.0/24;
            allow 192.168.60.0/24;
            deny all;
          '';
        };
      };
    };
  };

  systemd.services.nginx = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };

  users.users.nginx.extraGroups = [ "acme" ];
}
