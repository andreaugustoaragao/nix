{
  config,
  hostName,
  lib,
  ...
}:
{
  config = lib.mkIf (hostName == "tala") {
    sops.secrets.immich_oidc_client_secret = {
      sopsFile = ../../secrets/tala.yaml;
      restartUnits = [ "immich-server.service" ];
    };
    services.immich.settings.oauth = {
      enabled = true;
      issuerUrl = "https://auth.faragao.net/application/o/immich/";
      clientId = "faragao-immich";
      clientSecret._secret = config.sops.secrets.immich_oidc_client_secret.path;
      scope = "openid email profile";
      buttonText = "Sign in with Google";
      autoRegister = true;
    };
  };
}
