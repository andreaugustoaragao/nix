{
  config,
  lib,
  ...
}:

{
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_port = 3000;
        http_addr = "127.0.0.1";
      };
      "auth.anonymous" = {
        enabled = true;
        org_role = "Admin";
      };
      auth.disable_login_form = true;
      analytics.reporting_enabled = false;
      analytics.check_for_updates = false;
    };
    provision.datasources.settings = {
      apiVersion = 1;
      datasources = [
        {
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://localhost:3101";
          isDefault = true;
          editable = true;
        }
      ];
    };
  };

  systemd.services.grafana = {
    after = [ "loki.service" ];
    wants = [ "loki.service" ];
  };
}
