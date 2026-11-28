_: {
  # SOPS secrets configuration scoped strictly to maui (*admin_key + *maui_key).
  sops = {
    defaultSopsFile = ../../secrets/maui.yaml;
    validateSopsFiles = true;

    age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = true;
    };

    secrets = {
      "adm_password" = {
        owner = "root";
        group = "root";
        mode = "0400";
        neededForUsers = true;
      };

      "root_password" = {
        owner = "root";
        group = "root";
        mode = "0400";
        neededForUsers = true;
      };

      "grafana_secret_key" = {
        owner = "grafana";
        group = "grafana";
        mode = "0400";
        restartUnits = [ "grafana.service" ];
      };

      "grafana_oauth_client_secret" = {
        owner = "grafana";
        group = "grafana";
        mode = "0400";
        restartUnits = [ "grafana.service" ];
      };

      "continuwuity_oidc_client_secret" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "continuwuity.service" ];
      };

      "vaultwarden_env" = {
        owner = "root";
        group = "root";
        mode = "0600";
        restartUnits = [ "vaultwarden.service" ];
      };

      "acme_cloudflare_env" = {
        owner = "acme";
        group = "acme";
        mode = "0400";
      };

      "matrix_bot_token" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "matrix_alert_room_id" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "healthchecks_upgrade_url" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "nginx_origin_cert" = {
        owner = "nginx";
        group = "nginx";
        mode = "0400";
        restartUnits = [ "nginx.service" ];
      };

      "nginx_origin_key" = {
        owner = "nginx";
        group = "nginx";
        mode = "0400";
        restartUnits = [ "nginx.service" ];
      };

      "alertmanager_env" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "alertmanager.service" ];
      };

      "snmp_exporter_env" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "prometheus-snmp-exporter.service" ];
      };

      "fleet_reporter_env" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "loki_push_env" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "alloy.service" ];
      };

      "loki_query_env" = {
        owner = "grafana";
        group = "grafana";
        mode = "0400";
        restartUnits = [ "grafana.service" ];
      };
    };
  };
}
