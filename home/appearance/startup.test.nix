{ lib }:
let
  # Inspect startup wiring without realizing any of the generated applications.
  module = import ./default.nix {
    inherit lib;
    config = { };
    pkgs = { };
    unstable-pkgs = { };
    appearance.isGruvbox = true;
    useNoctalia = true;
  };
  service = module.config.content.systemd.user.services.noctalia.Service;
in
assert lib.assertMsg (!(service ? ExecStartPost))
  "Noctalia appearance startup must not depend on post-start IPC; prepare settings before ExecStart.";
assert service ? ExecStartPre;
true
