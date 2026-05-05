{ config, ... }:

{
  services.authelia.instances.main = {
    enable = true;

    secrets = {
      jwtSecretFile = config.sops.secrets."authelia/jwt_secret".path;
      storageEncryptionKeyFile = config.sops.secrets."authelia/storage_encryption_key".path;
      sessionSecretFile = config.sops.secrets."authelia/session_secret".path;
      oidcHmacSecretFile = config.sops.secrets."authelia/hmac_secret".path;
      oidcIssuerPrivateKeyFile = config.sops.secrets."authelia/jwt_private_key".path;
    };

    settings = {
      server.address = "tcp://127.0.0.1:9091";
      log.level = "info";

      authentication_backend.ldap = {
        implementation = "lldap";
        address = "ldap://127.0.0.1:3890";
        base_dn = "dc=faragao,dc=net";
        user = "uid=admin,ou=people,dc=faragao,dc=net";
        # Password injected via AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE
        # in environmentVariables below.
      };

      access_control.default_policy = "two_factor";

      session = {
        cookies = [
          {
            domain = "faragao.net";
            authelia_url = "https://auth.faragao.net";
            default_redirection_url = "https://auth.faragao.net";
          }
        ];
        expiration = "1h";
        inactivity = "5m";
      };

      storage.local.path = "/var/lib/authelia-main/db.sqlite3";

      notifier.filesystem.filename = "/var/lib/authelia-main/notification.txt";

      # OIDC issuer is configured (keys live in `secrets` above) but no
      # clients are registered yet. Add Immich, Vaultwarden, etc. here
      # once their hosts exist.
      identity_providers.oidc = {
        clients = [ ];
      };
    };

    environmentVariables = {
      AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE =
        config.sops.secrets."lldap/admin_password".path;
    };
  };
}
