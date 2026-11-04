{ pkgs, home-manager }:
let
  inherit (pkgs) lib;
  revision = "0123456789abcdef0123456789abcdef01234567";
  release =
    pkgs.runCommand "shared-vault-inert-test-release" { passthru.sharedVaultSourceRevision = revision; }
      ''
        mkdir -p "$out/bin"
        cat > "$out/bin/vault-client" <<'SH'
        #!${pkgs.runtimeShell}
        exec ${lib.getExe pkgs.python3} -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"
        SH
        chmod +x "$out/bin/vault-client"
        cp "$out/bin/vault-client" "$out/bin/vault-mcp"
      '';
  evaluate =
    settings:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        personalOnly = true;
        isServer = false;
      };
      modules = [
        ./shared-vault.nix
        ./opencode.nix
        {
          options.services.piModels.providers = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          config = {
            home = {
              username = "fixture";
              homeDirectory = "/home/fixture";
              stateVersion = "26.05";
            };
            my.sharedVault = settings;
          };
        }
      ];
    };
  settings = {
    enable = true;
    vaultId = "fixture-vault";
    runtimeDirectory = "/run/user/1000/shared-vault-fixture";
    inherit release;
    releaseId = revision;
  };
  enabled = (evaluate settings).config;
  disabled = (evaluate { }).config;
  invalid =
    (evaluate (settings // { releaseId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; })).config;
  tooLong =
    (evaluate (settings // { runtimeDirectory = "/${lib.concatStrings (lib.replicate 90 "a")}"; }))
    .config;
  valid = cfg: lib.all (item: item.assertion) cfg.assertions;
  rejectedIds =
    map
      (vaultId: !(builtins.tryEval (valid (evaluate (settings // { inherit vaultId; })).config)).success)
      [
        "fixture.vault"
        (lib.concatStrings (lib.replicate 65 "a"))
      ];
  launchers = lib.findFirst (
    package: package.name == "shared-vault-clients"
  ) null enabled.home.packages;
  connection =
    pkgs.writeText "shared-vault-test-connection.json"
      enabled.xdg.configFile."shared-vault/connection.json".text;
  opencode = enabled.xdg.configFile."opencode/opencode.jsonc".source;
  python = pkgs.python3.withPackages (ps: [
    ps.tomlkit
    ps.json5
  ]);
  activationSteps =
    cfg:
    lib.filterAttrs (
      name: _:
      builtins.elem name [
        "sharedVaultClientsPrepare"
        "sharedVaultClients"
        "linkGeneration"
        "writeBoundary"
      ]
    ) cfg.home.activation;
  activation = pkgs.writeText "shared-vault-test-activation.json" (
    builtins.toJSON {
      enabled = activationSteps enabled;
      disabled = activationSteps disabled;
    }
  );
in
assert valid enabled;
assert valid disabled;
assert !(builtins.tryEval (valid invalid)).success;
assert !(builtins.tryEval (valid tooLong)).success;
assert lib.all (value: value) rejectedIds;
assert valid
  (evaluate (settings // { vaultId = lib.concatStrings (lib.replicate 64 "a"); })).config;
assert !(disabled.xdg.configFile ? "shared-vault/connection.json");
assert disabled.home.activation ? sharedVaultClients;
pkgs.runCommand "check-shared-vault-module" { } ''
  cp ${./shared-vault-configure.py} shared-vault-configure.py
  cp ${./shared-vault-module.test.py} shared-vault-module.test.py
  PYTHONDONTWRITEBYTECODE=1 ${lib.getExe python} shared-vault-module.test.py \
    ${enabled.my.sharedVault.registrationManifest} \
    ${disabled.my.sharedVault.registrationManifest} \
    ${connection} ${opencode} ${launchers} ${activation}
  touch "$out"
''
