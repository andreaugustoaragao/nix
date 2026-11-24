{ pkgs, home-manager }:
let
  inherit (pkgs) lib;
  fixtureHome = "/home/fulcrum-release-fixture";
  vaultPkg = pkgs.runCommand "fulcrum-inert-vault-fixture" { } "mkdir -p $out/bin";
  appPkg =
    pkgs.runCommand "fulcrum-inert-app-fixture" { }
      "mkdir -p $out/bin $out/share/vault-services";
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
            my.vaultV2 = {
              enable = mode == "v2";
              package = vaultPkg;
              fulcrumRelease = if mode == "v2" then appPkg else null;
            };
          };
        }
      ];
    }).config.systemd.user.services.fulcrum;
  packagedV2 = evaluate "v2";
  source = evaluate "source";
  runtimeRoot = "${appPkg}/share/vault-services";
in
assert packagedV2.Service.WorkingDirectory == runtimeRoot;
assert !(packagedV2.Unit ? ConditionPathExists);
assert source.Service.WorkingDirectory == "${fixtureHome}/projects/work/fulcrum";
assert source.Unit.ConditionPathExists == source.Service.WorkingDirectory;
assert builtins.elem "FULCRUM_V2_STATE_DIR=${fixtureHome}/.local/share/fulcrum-v2/app"
  packagedV2.Service.Environment;
assert builtins.elem "FULCRUM_VAULT_DIR=${fixtureHome}/projects/work/notes"
  packagedV2.Service.Environment;
assert builtins.elem "FULCRUM_VAULT_V2_SOCKET=%t/shared-vault-v2/api.sock"
  packagedV2.Service.Environment;
assert builtins.elem "FULCRUM_SCHEDULER_SOCKET=%t/ai-task-scheduler/api.sock"
  packagedV2.Service.Environment;
assert builtins.elem "FULCRUM_CALLBACK_SOCKET=%t/fulcrum-v2/callback.sock"
  packagedV2.Service.Environment;
assert
  !(builtins.elem "FULCRUM_DATA_DIR=${fixtureHome}/projects/work/notes/.fulcrum" packagedV2.Service.Environment);
assert !(builtins.elem "CHROMA_BASE_URL=http://localhost:8000" packagedV2.Service.Environment);
assert builtins.elem "CHROMA_BASE_URL=http://localhost:8000" source.Service.Environment;
assert
  !(builtins.elem "FULCRUM_VAULT_V2_SOCKET=%t/shared-vault-v2/api.sock" source.Service.Environment);
assert builtins.elem "file://${runtimeRoot}/docs/README.md" packagedV2.Unit.Documentation;
pkgs.runCommand "check-fulcrum-packaged-runtime" { } ''
  execStart=${builtins.head packagedV2.Service.ExecStart}
  grep -F -- ${lib.escapeShellArg "${appPkg}/bin/bun"} "$execStart"
  grep -F -- ${lib.escapeShellArg "${runtimeRoot}/v2/server/src/main.ts"} "$execStart"
  grep -F -- ${lib.escapeShellArg "${fixtureHome}/.local/share/fulcrum-v2/app/.env"} "$execStart"
  if grep -F -- ${lib.escapeShellArg "${fixtureHome}/projects/work/fulcrum"} "$execStart"; then
    echo 'Packaged service still depends on a development checkout' >&2
    exit 1
  fi
  grep -F -- 'run start' ${builtins.head source.Service.ExecStart}
  touch "$out"
''
