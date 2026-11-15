{
  lib,
  pkgs,
  osConfig,
  isDarwinHost ? false,
  ...
}:
{
  home.activation.rootlessDockerContext =
    lib.mkIf (!isDarwinHost && osConfig.virtualisation.docker.rootless.enable)
      (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          docker=${lib.getExe pkgs.docker_29}
          socket="unix:///run/user/$(${pkgs.coreutils}/bin/id -u)/docker.sock"
          if ! "$docker" context inspect rootless >/dev/null 2>&1; then
            run "$docker" context create rootless --docker "host=$socket"
          else
            run "$docker" context update rootless --docker "host=$socket" >/dev/null
          fi
          # Existing shells also use the user daemon. Keep explicitly chosen remote contexts.
          current_context=$("$docker" context show)
          if [ "$current_context" = default ] || [ "$current_context" = rootless ]; then
            run "$docker" context use rootless >/dev/null
          fi
        ''
      );
}
