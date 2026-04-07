{
  config,
  lib,
  hostName,
  isVm,
  ...
}:

{
  services.caddy = {
    enable = true;
    virtualHosts = lib.mkMerge [
      {
        "http://grafana.local" = {
          extraConfig = "reverse_proxy 127.0.0.1:3000";
        };
        "http://loki.local" = {
          extraConfig = "reverse_proxy 127.0.0.1:3101";
        };
        "http://prometheus.local" = {
          extraConfig = "reverse_proxy 127.0.0.1:9090";
        };
      }
      (lib.mkIf (hostName == "prl-dev-vm") {
        "http://fulcrum.local" = {
          extraConfig = "reverse_proxy 127.0.0.1:3100";
        };
      })
      (lib.mkIf (!isVm) {
        "http://ollama.local" = {
          extraConfig = "reverse_proxy 127.0.0.1:11434";
        };
      })
    ];
  };
}
