{ pkgs, home-manager }:
let
  inherit (pkgs) lib;
  fixtureHome = "/home/fulcrum-release-fixture";
  release = pkgs.runCommand "fulcrum-inert-release-fixture" { } "mkdir -p $out";
  evaluate =
    packaged:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        hostName = "vmw-dev-vm";
        isWorkstation = false;
        unstable-pkgs = pkgs;
        osConfig.sops.secrets = {
          litellm_api_key.path = "/run/secrets/fixture-api-key";
          litellm_base_url.path = "/run/secrets/fixture-base-url";
          "matrix/bot_token".path = "/run/secrets/fixture-matrix-token";
        };
      };
      modules = [
        ./fulcrum.nix
        {
          options.my.sharedVault = lib.mkOption { type = lib.types.attrs; };
          config = {
            home.username = "fulcrum-release-fixture";
            home.homeDirectory = fixtureHome;
            home.stateVersion = "26.05";
            my.sharedVault = {
              enable = packaged;
              inherit release;
              service.environment = { };
            };
          };
        }
      ];
    }).config.systemd.user.services.fulcrum;
  packaged = evaluate true;
  source = evaluate false;
  runtimeRoot = "${release}/share/vault-services";
in
assert packaged.Service.WorkingDirectory == runtimeRoot;
assert !(packaged.Unit ? ConditionPathExists);
assert source.Service.WorkingDirectory == "${fixtureHome}/projects/work/fulcrum";
assert source.Unit.ConditionPathExists == source.Service.WorkingDirectory;
assert builtins.elem "FULCRUM_DATA_DIR=${fixtureHome}/projects/work/notes/.fulcrum"
  packaged.Service.Environment;
assert builtins.elem "file://${runtimeRoot}/docs/README.md" packaged.Unit.Documentation;
pkgs.runCommand "check-fulcrum-packaged-runtime" { } ''
  grep -F -- ${lib.escapeShellArg "${release}/bin/bun"} ${builtins.head packaged.Service.ExecStart}
  grep -F -- ${lib.escapeShellArg "${runtimeRoot}/src/index.ts"} ${builtins.head packaged.Service.ExecStart}
  grep -F -- ${lib.escapeShellArg "--env-file=${fixtureHome}/projects/work/notes/.fulcrum/.env"} ${builtins.head packaged.Service.ExecStart}
  if grep -F -- ${lib.escapeShellArg "${fixtureHome}/projects/work/fulcrum"} ${builtins.head packaged.Service.ExecStart}; then
    echo 'Packaged service still depends on a development checkout' >&2
    exit 1
  fi
  grep -F -- 'run start' ${builtins.head source.Service.ExecStart}
  touch "$out"
''
