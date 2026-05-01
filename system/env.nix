{ config, pkgs, lib, inputs, ... }:

{
  environment.sessionVariables = {
    XDG_DATA_DIRS = lib.mkDefault "/run/current-system/sw/share:/etc/profiles/per-user/$USER/share";
    JAVA_HOME = "/run/current-system/sw/lib/openjdk";
    # Make Node.js (used by Claude Code, etc.) use the system CA bundle with enterprise certs
    NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
    ENABLE_TOOL_SEARCH = "true";
  };

  # Use dash for /bin/sh — small, fast, POSIX. Affects systemd ExecStart
  # `sh -c …`, build-sandbox shells, and any unshebanged scripts that
  # run via /bin/sh. Interactive shells (fish/zsh/bash) are unchanged.
  # Revert by removing this line if anything upstream assumes bash at
  # /bin/sh and breaks.
  environment.binsh = "${pkgs.dash}/bin/dash";
} 