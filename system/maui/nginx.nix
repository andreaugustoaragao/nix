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
