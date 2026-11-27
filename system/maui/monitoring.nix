{
  config,
  ...
}:
{
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
    enabledCollectors = [
      "logind"
      "systemd"
      "processes"
    ];
    disabledCollectors = [
      "textfile"
    ];
  };
  # https://wiki.nixos.org/wiki/Prometheus
  # https://nixos.org/manual/nixos/stable/#module-services-prometheus-exporters-configuration
  # https://github.com/NixOS/nixpkgs/blob/nixos-24.05/nixos/modules/services/monitoring/prometheus/default.nix
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    globalConfig.scrape_interval = "10s"; # "1m"
    retentionTime = "30d";
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [
          {
            targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ];
          }
        ];
      }
    ];
  };

  services.grafana = {
    enable = true;
    settings.server.domain = "monitoring.faragao.net";
    settings.server.http_port = 2342;
    settings.server.http_addr = "127.0.0.1";
    settings.security.secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
  };

  systemd.services.grafana = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };

  services.nginx.virtualHosts.${config.services.grafana.settings.server.domain} = {
    forceSSL = true;
    useACMEHost = "faragao.net";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
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
}
