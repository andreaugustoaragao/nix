{ config, ... }:

{
  services.lldap = {
    enable = true;
    settings = {
      http_url = "https://lldap.faragao.net";
      http_host = "127.0.0.1";
      http_port = 17170;
      ldap_host = "0.0.0.0";
      ldap_port = 3890;
      ldap_base_dn = "dc=faragao,dc=net";
      ldap_user_dn = "admin";
      ldap_user_email = "admin@faragao.net";
      ldap_user_pass_file = config.sops.secrets."lldap/admin_password".path;
      # Always reset admin password from the file on startup so the
      # config and sops-managed password can't drift.
      force_ldap_user_pass_reset = "always";
      verbose = false;
    };
  };
}
