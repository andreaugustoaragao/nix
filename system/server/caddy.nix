{ ... }:

{
  # Reverse-proxy vhosts for the auth stack. The wildcard cert is
  # issued by security.acme (see ./acme.nix) and consumed via
  # useACMEHost — Caddy's built-in ACME is bypassed in favor of the
  # already-proven DNS-01 path used elsewhere on the network.
  services.caddy.virtualHosts = {
    "auth.faragao.net" = {
      useACMEHost = "faragao.net";
      extraConfig = ''
        reverse_proxy 127.0.0.1:9091
      '';
    };
    "lldap.faragao.net" = {
      useACMEHost = "faragao.net";
      extraConfig = ''
        reverse_proxy 127.0.0.1:17170
      '';
    };
  };

  users.users.caddy.extraGroups = [ "acme" ];
}
