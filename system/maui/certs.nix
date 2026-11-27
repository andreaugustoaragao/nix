{ config, ... }:
{
  security.acme = {
    acceptTerms = true;
    defaults.email = "adm@faragao.net";
    defaults.renewInterval = "daily";
    defaults.environmentFile = config.sops.secrets.acme_cloudflare_env.path;
    defaults.dnsProvider = "cloudflare";
    defaults.dnsResolver = "1.1.1.1";
    defaults.validMinDays = 88;
    certs."faragao.net" = {
      extraDomainNames = [
        "*.faragao.net"
      ];
    };
  };

  systemd.services."acme-faragao.net" = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };
}
