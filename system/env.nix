{ config, pkgs, lib, inputs, ... }:

{
  environment.sessionVariables = {
    XDG_DATA_DIRS = lib.mkDefault "/run/current-system/sw/share:/etc/profiles/per-user/$USER/share";
    JAVA_HOME = "/run/current-system/sw/lib/openjdk";
  };
} 