{ pkgs, home-manager }:
let
  inherit (pkgs) lib;
  revision = "0123456789abcdef0123456789abcdef01234567";
  embeddingCache = "/home/fixture/.cache/fulcrum/embeddings";
  release =
    pkgs.runCommand "shared-vault-inert-test-release"
      {
        version = "0.224.2";
        passthru = {
          sharedVaultSourceRevision = revision;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          sharedVaultSdkCcLib = pkgs.stdenv.cc.cc.lib;
          sharedVaultSdkIcu = pkgs.icu;
        };
      }
      ''
        mkdir -p "$out/bin" "$out/share/vault-services"
        cat > "$out/bin/vault-client" <<'SH'
        #!${pkgs.runtimeShell}
        exec ${lib.getExe pkgs.python3} -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"
        SH
        chmod +x "$out/bin/vault-client"
        cp "$out/bin/vault-client" "$out/bin/vault-mcp"
        cp "$out/bin/vault-client" "$out/bin/vault-service"
        cat > "$out/share/vault-services/release.json" <<JSON
        {"packageVersion":"$version","source":{"kind":"artifact","revision":"${revision}"}}
        JSON
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
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ../services/shared-vault.nix ]
      ++ [
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
  serviceEnabled =
    (evaluate (
      settings
      // {
        service = {
          enable = true;
          notesDir = "/tmp/shared-vault-fixture-notes";
          stateDir = "/tmp/shared-vault-fixture-state";
          recordingsDirectory = "/tmp/shared-vault-fixture-recordings";
          vector.namespace = "fixture-vault";
          environment.FULCRUM_EMBEDDING_CACHE_DIR = embeddingCache;
        };
      }
    )).config;
  serviceInvalid =
    (evaluate (
      settings
      // {
        service = {
          enable = true;
          environment.FULCRUM_EMBEDDING_CACHE_DIR = embeddingCache;
        };
      }
    )).config;
  recordingService =
    intake:
    (evaluate (
      settings
      // {
        service = {
          enable = true;
          notesDir = "/tmp/shared-vault-fixture-notes";
          stateDir = "/tmp/shared-vault-fixture-state";
          recordingsDirectory = "/tmp/shared-vault-fixture-recordings";
          vector.namespace = "fixture-vault";
          environment.FULCRUM_EMBEDDING_CACHE_DIR = embeddingCache;
          automation = {
            enable = true;
            executable = "/fixture/bin/codex";
          };
          recordingIntake = intake;
        };
      }
    )).config;
  recordingMinimal = recordingService { agentName = "exec-assistant"; };
  recordingUnicode = recordingService {
    agentName = lib.concatStrings (lib.replicate 200 "é");
    model = lib.concatStrings (lib.replicate 200 "😀");
    recordCall = "/${lib.concatStrings (lib.replicate 4095 "é")}";
    google = {
      account = "中@文";
      executable = "/fixture/bin/google-reader";
    };
  };
  invalidRecordingText =
    map
      (
        intake:
        !(builtins.tryEval (
          builtins.deepSeq (recordingService intake).my.sharedVault.service.recordingIntake true
        )).success
      )
      [
        { agentName = lib.concatStrings (lib.replicate 201 "é"); }
        {
          agentName = "exec-assistant";
          recordCall = "/${lib.concatStrings (lib.replicate 4096 "é")}";
        }
        {
          agentName = "exec-assistant";
          recordCall = "relative/record-call";
        }
        {
          agentName = "exec-assistant";
          google = {
            account = "fixture@example.test";
            executable = "/${lib.concatStrings (lib.replicate 4096 "😀")}";
          };
        }
        {
          agentName = "exec-assistant";
          model = lib.concatStrings (lib.replicate 201 "😀");
        }
        {
          agentName = "exec-assistant";
          google = {
            account = "中";
            executable = "/fixture/bin/google-reader";
          };
        }
      ];
  recordingComplete = recordingService {
    agentName = "exec-assistant";
    model = "fixture-model";
    systemPromptAppend = "Preserve existing meeting links.";
    recordCall = "/fixture/bin/record-call";
    google = {
      account = "fixture@example.test";
      executable = "/fixture/bin/google-reader";
    };
  };
  recordingWithoutOwner =
    (evaluate (
      settings
      // {
        service = {
          enable = true;
          notesDir = "/tmp/shared-vault-fixture-notes";
          stateDir = "/tmp/shared-vault-fixture-state";
          recordingsDirectory = "/tmp/shared-vault-fixture-recordings";
          vector.namespace = "fixture-vault";
          environment.FULCRUM_EMBEDDING_CACHE_DIR = embeddingCache;
          recordingIntake.agentName = "exec-assistant";
        };
      }
    )).config;
  serviceDiagnostics = lib.findFirst (
    package: package.name == "vault-service-config"
  ) null serviceEnabled.home.packages;
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
assert !pkgs.stdenv.hostPlatform.isLinux || valid serviceEnabled;
assert !pkgs.stdenv.hostPlatform.isLinux || valid recordingMinimal;
assert !pkgs.stdenv.hostPlatform.isLinux || valid recordingComplete;
assert !pkgs.stdenv.hostPlatform.isLinux || valid recordingUnicode;
assert !pkgs.stdenv.hostPlatform.isLinux || lib.all (rejected: rejected) invalidRecordingText;
assert
  !pkgs.stdenv.hostPlatform.isLinux || !(builtins.tryEval (valid recordingWithoutOwner)).success;
assert !pkgs.stdenv.hostPlatform.isLinux || !(builtins.tryEval (valid serviceInvalid)).success;
assert
  !pkgs.stdenv.hostPlatform.isLinux || serviceEnabled.xdg.configFile ? "shared-vault/service.json";
assert
  !pkgs.stdenv.hostPlatform.isLinux
  || serviceEnabled.xdg.configFile ? "systemd/user/shared-vault.service";
assert
  !pkgs.stdenv.hostPlatform.isLinux
  || serviceEnabled.xdg.configFile."systemd/user/shared-vault.service".source != null;
assert !pkgs.stdenv.hostPlatform.isLinux || serviceDiagnostics != null;
assert
  !pkgs.stdenv.hostPlatform.isLinux || (builtins.tryEval (toString serviceDiagnostics)).success;
assert
  !pkgs.stdenv.hostPlatform.isLinux
  || lib.elem
    "FULCRUM_EMBEDDING_CACHE_DIR=${embeddingCache}"
    serviceEnabled.systemd.user.services.shared-vault.Service.Environment;
assert
  !pkgs.stdenv.hostPlatform.isLinux
  || lib.any
    (lib.hasPrefix "${release}/bin/vault-service --config ")
    serviceEnabled.systemd.user.services.shared-vault.Service.ExecStart;
assert
  !pkgs.stdenv.hostPlatform.isLinux
  || lib.any (lib.hasInfix "--release-manifest ") serviceEnabled.systemd.user.services.shared-vault.Service.ExecStart;
pkgs.runCommand "check-shared-vault-module" { } ''
  test -x ${release}/bin/vault-service
  test -s ${release}/share/vault-services/release.json
  cp ${./shared-vault-configure.py} shared-vault-configure.py
  cp ${./shared-vault-module.test.py} shared-vault-module.test.py
  PYTHONDONTWRITEBYTECODE=1 ${lib.getExe python} shared-vault-module.test.py \
    ${enabled.my.sharedVault.registrationManifest} \
    ${disabled.my.sharedVault.registrationManifest} \
    ${connection} ${opencode} ${launchers} ${activation}
  ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    ${lib.getExe python} -c 'import json,sys; assert json.load(open(sys.argv[1]))["recordings"] == {"directory":"/tmp/shared-vault-fixture-recordings"}' \
      ${serviceEnabled.xdg.configFile."shared-vault/service.json".source}
    ${lib.getExe python} - <<'PY'
    import json
    from pathlib import Path
    unicode = json.loads(Path("${
      recordingUnicode.xdg.configFile."shared-vault/service.json".source
    }").read_text())
    minimal = json.loads(Path("${
      recordingMinimal.xdg.configFile."shared-vault/service.json".source
    }").read_text())
    complete = json.loads(Path("${
      recordingComplete.xdg.configFile."shared-vault/service.json".source
    }").read_text())
    assert minimal["recordings"]["intake"] == {"agentName": "exec-assistant"}
    assert complete["recordings"]["intake"] == {
        "agentName": "exec-assistant", "model": "fixture-model", "systemPromptAppend": "Preserve existing meeting links.",
        "recordCall": "/fixture/bin/record-call", "google": {"account": "fixture@example.test", "executable": "/fixture/bin/google-reader"}}
    for config in (minimal, complete):
        assert config["automation"]["activation"] == config["automation"]["recordingAdmission"] == "paused"
    print("Recording profiles serialize exactly with both admission settings paused")
    assert unicode["recordings"]["intake"] == {"agentName": "é" * 200, "model": "😀" * 200, "recordCall": "/" + "é" * 4095,
        "google": {"account": "中@文", "executable": "/fixture/bin/google-reader"}}
    print("Unicode profile limits match code points for accented, CJK and supplementary characters")
    PY
  ''}
  touch "$out"
''
