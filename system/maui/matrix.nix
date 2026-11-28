{
  config,
  lib,
  pkgs,
  ...
}:
let
  cloudflare = import ./cloudflare-ips.nix;
  # Hits continuwuity directly on localhost rather than going through
  # matrix.faragao.net -> Cloudflare -> nginx -> continuwuity. That
  # means alerts can still fire when nginx or
  # the cert chain are the failing service.
  matrixAlert = pkgs.writeShellScript "matrix-alert" ''
    set -euo pipefail

    unit="''${1:-unknown}"
    host=$(${pkgs.nettools}/bin/hostname)
    msg="$unit failed on $host"

    token=$(cat ${config.sops.secrets.matrix_bot_token.path})
    room=$(cat ${config.sops.secrets.matrix_alert_room_id.path})
    txn=$(date +%s%N)

    body=$(${pkgs.jq}/bin/jq -n --arg body "$msg" '{msgtype:"m.text",body:$body}')

    exec ${pkgs.curl}/bin/curl -fsS --retry 3 --max-time 15 -X PUT \
      "http://127.0.0.1:6167/_matrix/client/v3/rooms/$room/send/m.room.message/$txn" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  '';

  # Services whose failure should land in the Matrix alert room. Each
  # name produces an OnFailure=matrix-alert@<name>.service link.
  # continuwuity itself is intentionally excluded — if the homeserver
  # is down, the alert can't be delivered through it.
  alertedServices = [
    "vaultwarden"
    "nginx"
    "acme-faragao.net"
    "samba-smbd"
    "prometheus"
    "grafana"
    "alloy"
  ];
in
{
  users.users.continuwuity = {
    uid = 989;
    isSystemUser = true;
    group = "continuwuity";
  };
  users.groups.continuwuity = {
    gid = 986;
  };

  systemd.tmpfiles.rules = [
    "d /data/services/matrix 0700 continuwuity continuwuity -"
  ];

  services.matrix-continuwuity = {
    enable = true;
    settings.global = {
      server_name = "matrix.faragao.net";
      address = [ "127.0.0.1" ];
      port = [ 6167 ];
      allow_federation = false;
      allow_encryption = true;
      allow_registration = false;
      new_user_displayname_suffix = "";
      max_request_size = 20000000;
      well_known.client = "https://matrix.faragao.net";
      oauth.oidc = {
        discovery_url = "https://auth.faragao.net/application/o/matrix/";
        client_id = "faragao-matrix";
        client_secret_file = "/run/credentials/continuwuity.service/oidc_client_secret";
        additional_scopes = [
          "email"
          "profile"
        ];
        provider_name = "faragao.net";
        prompt_for_localpart = true;
      };
    };
  };

  systemd.services = {
    continuwuity = {
      after = [
        "data.mount"
        "nginx.service"
      ];
      requires = [ "data.mount" ];
      wants = [ "nginx.service" ];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "continuwuity";
        Group = lib.mkForce "continuwuity";
        LoadCredential = "oidc_client_secret:${config.sops.secrets.continuwuity_oidc_client_secret.path}";
        BindPaths = [ "/data/services/matrix:/var/lib/continuwuity" ];
      };
    };

    "matrix-alert@" = {
      description = "Post Matrix alert for %i";
      unitConfig = {
        ConditionPathExists = [
          config.sops.secrets.matrix_bot_token.path
          config.sops.secrets.matrix_alert_room_id.path
        ];
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${matrixAlert} %i";
      };
    };
  }
  // lib.genAttrs alertedServices (name: {
    onFailure = [ "matrix-alert@${name}.service" ];
  });

  services.nginx.virtualHosts."matrix.faragao.net" =
    let
      ingress = ''
        allow 127.0.0.1;
        allow 192.168.10.0/24;
        allow 192.168.20.0/24;
        allow 192.168.40.10;
        allow 192.168.50.0/24;
        allow 192.168.60.0/24;
        # Cloudflare IPv4 ranges (https://www.cloudflare.com/ips-v4)
        ${cloudflare.nginxAllowBlock}
        deny all;
      '';
      familySite = builtins.path {
        name = "faragao-family-site";
        path = ../../assets/family-chat;
      };
    in
    {
      forceSSL = true;
      useACMEHost = "faragao.net";
      locations."= /" = {
        root = familySite;
        tryFiles = "/index.html =404";
        extraConfig = ingress;
      };
      locations."^~ /brand/" = {
        root = familySite;
        extraConfig = ingress;
      };
      locations."/" = {
        proxyPass = "http://127.0.0.1:6167";
        recommendedProxySettings = true;
        proxyWebsockets = true;
        extraConfig = ''
          client_max_body_size 20M;
          ${ingress}
        '';
      };
    };
}
