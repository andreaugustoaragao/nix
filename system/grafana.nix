_:

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
      # 26.05 dropped the built-in default for secret_key. This instance runs
      # anonymous-admin with a single credential-less Loki datasource, so its DB
      # holds nothing worth protecting; we pin the old public default so any
      # pre-existing DB entries stay decryptable (changelog-sanctioned path for
      # setups with no sensitive secrets).
      security.secret_key = "SW2YcwTIb9zpOOhoPsMm";
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
