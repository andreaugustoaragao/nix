{
  config,
  lib,
  ...
}:

{
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_port = 3101;
        log_level = "warn";
      };
      common = {
        path_prefix = "/var/lib/loki";
        replication_factor = 1;
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
      };
      schema_config.configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      storage_config.filesystem.directory = "/var/lib/loki/chunks";
      limits_config = {
        retention_period = "744h"; # 31 days
        allow_structured_metadata = true;
        volume_enabled = true;
      };
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        delete_request_store = "filesystem";
        retention_enabled = true;
        compaction_interval = "10m";
      };
    };
  };
}
