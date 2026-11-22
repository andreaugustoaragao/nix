{ pkgs, home-manager }:
let
  inherit (pkgs) lib;
  fixtureHome = "/home/fulcrum-release-fixture";
  release = pkgs.runCommand "fulcrum-inert-release-fixture" { } "mkdir -p $out";
  evaluate =
    mode:
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
          options.my.sharedVault = lib.mkOption {
            type = lib.types.attrs;
            default = {
              enable = false;
            };
          };
          options.my.vaultV2 = lib.mkOption {
            type = lib.types.attrs;
            default = {
              enable = false;
            };
          };
          config = {
            home.username = "fulcrum-release-fixture";
            home.homeDirectory = fixtureHome;
            home.stateVersion = "26.05";
            my.sharedVault = {
              enable = mode == "legacy";
              inherit release;
              service.environment = { };
            };
            my.vaultV2 = {
              enable = mode == "v2";
              package = release;
              fulcrumRelease = if mode == "v2" then release else null;
            };
          };
        }
      ];
    }).config.systemd.user.services.fulcrum;
  packaged = evaluate "legacy";
  packagedV2 = evaluate "v2";
  source = evaluate "source";
  runtimeRoot = "${release}/share/vault-services";
in
assert packaged.Service.WorkingDirectory == runtimeRoot;
assert !(packaged.Unit ? ConditionPathExists);
assert packagedV2.Service.WorkingDirectory == runtimeRoot;
assert !(packagedV2.Unit ? ConditionPathExists);
assert source.Service.WorkingDirectory == "${fixtureHome}/projects/work/fulcrum";
assert source.Unit.ConditionPathExists == source.Service.WorkingDirectory;
assert builtins.elem "FULCRUM_DATA_DIR=${fixtureHome}/projects/work/notes/.fulcrum"
  packaged.Service.Environment;
assert builtins.elem "FULCRUM_DATA_DIR=${fixtureHome}/projects/work/notes/.fulcrum"
  packagedV2.Service.Environment;
assert builtins.elem "FULCRUM_VAULT_V2_SOCKET=%t/shared-vault-v2/api.sock"
  packagedV2.Service.Environment;
assert builtins.elem "FULCRUM_SCHEDULER_SOCKET=%t/ai-task-scheduler/api.sock"
  packagedV2.Service.Environment;
assert !(builtins.elem "CHROMA_BASE_URL=http://localhost:8000" packagedV2.Service.Environment);
assert builtins.elem "CHROMA_BASE_URL=http://localhost:8000" packaged.Service.Environment;
assert
  !(builtins.elem "FULCRUM_VAULT_V2_SOCKET=%t/shared-vault-v2/api.sock" packaged.Service.Environment);
assert builtins.elem "CHROMA_BASE_URL=http://localhost:8000" source.Service.Environment;
assert
  !(builtins.elem "FULCRUM_VAULT_V2_SOCKET=%t/shared-vault-v2/api.sock" source.Service.Environment);
assert builtins.elem "file://${runtimeRoot}/docs/README.md" packaged.Unit.Documentation;
assert builtins.elem "file://${runtimeRoot}/docs/README.md" packagedV2.Unit.Documentation;
pkgs.runCommand "check-fulcrum-packaged-runtime" { } ''
  for execStart in ${builtins.head packaged.Service.ExecStart} ${builtins.head packagedV2.Service.ExecStart}; do
    grep -F -- ${lib.escapeShellArg "${release}/bin/bun"} "$execStart"
    grep -F -- ${lib.escapeShellArg "${runtimeRoot}/src/index.ts"} "$execStart"
    grep -F -- ${lib.escapeShellArg "--env-file=${fixtureHome}/projects/work/notes/.fulcrum/.env"} "$execStart"
    if grep -F -- ${lib.escapeShellArg "${fixtureHome}/projects/work/fulcrum"} "$execStart"; then
      echo 'Packaged service still depends on a development checkout' >&2
      exit 1
    fi
  done
  grep -F -- 'run start' ${builtins.head source.Service.ExecStart}
  touch "$out"
''
