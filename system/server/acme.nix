{ config, ... }:

{
  # Wildcard cert for *.faragao.net via Cloudflare DNS-01.
  # Token is loaded from a sops-managed env file containing
  # CLOUDFLARE_DNS_API_TOKEN=<token>.
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "adm@faragao.net";
      dnsProvider = "cloudflare";
      dnsResolver = "1.1.1.1";
      environmentFile = config.sops.secrets."cloudflare_dns_token".path;
    };
    certs."faragao.net" = {
      extraDomainNames = [ "*.faragao.net" ];
    };
  };
}
