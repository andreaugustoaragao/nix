{ config, pkgs, lib, inputs, ... }:

{
  environment.sessionVariables = {
    XDG_DATA_DIRS = lib.mkDefault "/run/current-system/sw/share:/etc/profiles/per-user/$USER/share";
    JAVA_HOME = "/run/current-system/sw/lib/openjdk";
    # Make Node.js (used by Claude Code, etc.) use the system CA bundle with enterprise certs
    NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
  };
} 