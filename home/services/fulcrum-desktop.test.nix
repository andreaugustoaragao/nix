{
  pkgs,
  unstable-pkgs,
  homeManager,
}:
let
  fixture =
    hostName: package:
    (homeManager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inherit hostName unstable-pkgs;
        isWorkstation = hostName == "workstation";
        osConfig.sops.secrets = {
          litellm_api_key.path = "/run/secrets/fixture-api-key";
          litellm_base_url.path = "/run/secrets/fixture-base-url";
          "matrix/bot_token".path = "/run/secrets/fixture-matrix-token";
        };
      };
      modules = [
        ./fulcrum.nix
        ../desktop/fulcrum.nix
        {
          home.username = "fixture";
          home.homeDirectory = "/tmp/fulcrum-desktop-eval-fixture";
          home.stateVersion = "26.05";
          my.fulcrum.desktop.package = package;
        }
      ];
    }).config;
  vm = fixture "prl-dev-vm" pkgs.hello;
  disabled = fixture "prl-dev-vm" null;
  other = fixture "vmw-dev-vm" null;
  workstation = fixture "workstation" null;
  wrongHost = fixture "vmw-dev-vm" pkgs.hello;
  environment = c: c.systemd.user.services.fulcrum.Service.Environment;
  socket = "FULCRUM_DESKTOP_SOCKET=%t/fulcrum-desktop/session.sock";
  runtime = pkgs.callPackage ./fulcrum-runtime.nix { inherit unstable-pkgs; };
  named =
    name: packages:
    pkgs.lib.findFirst (
      package: (package.pname or "") == name
    ) (throw "Missing runtime package ${name}") packages;
  azureCore = named "azure-cli-core" runtime.azure-cli.basePackage.propagatedBuildInputs;
  tokenPackage = named "pyjwt" azureCore.propagatedBuildInputs;
  cryptoPackage = named "cryptography" azureCore.propagatedBuildInputs;
  identityPackage = named "msal" azureCore.propagatedBuildInputs;
  httpPackage = runtime.azure-cli.httpPackage;
  pathEntries =
    configuration:
    builtins.filter (entry: pkgs.lib.hasPrefix "PATH=" entry) (environment configuration);
  runtimeBinPath = pkgs.lib.makeBinPath [
    runtime.npm
    runtime.azure-cli
    runtime.ffmpeg
  ];
  runtimePrefix = "PATH=${runtimeBinPath}:";
  dropInName = "systemd/user/fulcrum.service.d/zz-fulcrum-runtime-tools.conf";
  ordinaryServicePath = pkgs.lib.removeSuffix ":/run/current-system/sw/bin" (
    pkgs.lib.removePrefix "PATH=" (builtins.head (pathEntries other))
  );
  expectedEffectivePath = pkgs.lib.concatStringsSep ":" [
    runtimeBinPath
    "/tmp/fulcrum-desktop-eval-fixture/.local/share/fulcrum/runtime/node-26.10.0/bin"
    "/tmp/fulcrum-desktop-eval-fixture/.local/share/fulcrum/runtime/bun-1.4.2/bin"
    ordinaryServicePath
    "/etc/profiles/per-user/fixture/bin"
    "/run/current-system/sw/bin"
  ];
  expectedDropIn = ''
    [Service]
    Environment="PATH=${expectedEffectivePath}"
  '';
in
assert runtime.azure-cli.version == "2.89.1";
assert runtime.azure-cli.basePackage == unstable-pkgs.azure-cli;
assert runtime.azure-cli.python == unstable-pkgs.python3;
assert (named "urllib3" runtime.azure-cli.basePackage.propagatedBuildInputs).version == "2.7.0";
assert azureCore.version == runtime.azure-cli.version;
assert pkgs.lib.versionAtLeast tokenPackage.version "2.14.0";
assert pkgs.lib.versionAtLeast cryptoPackage.version "50.0.0";
assert identityPackage.version == "1.37.0";
assert httpPackage.version == "2.8.0";
assert httpPackage.meta.changelog == "https://github.com/urllib3/urllib3/blob/2.8.0/CHANGES.rst";
assert runtime.ffmpeg.version == "9.0.1";
assert runtime.npm.node.version == "22.23.3";
assert runtime.npm.braceVersion == "2.1.7";
assert runtime.npm.node == pkgs.nodejs-slim_22;
assert runtime.npm.npmSource == pkgs.lib.getOutput "npm" pkgs.nodejs-slim_22;
assert runtime.npm.npmSource.outputName == "npm";
assert builtins.length (pathEntries vm) == 1;
assert pkgs.lib.hasPrefix runtimePrefix (builtins.head (pathEntries vm));
assert !(pkgs.lib.hasPrefix runtimePrefix (builtins.head (pathEntries other)));
assert !(pkgs.lib.hasPrefix runtimePrefix (builtins.head (pathEntries workstation)));
assert vm.xdg.configFile.${dropInName}.text == expectedDropIn;
assert disabled.xdg.configFile.${dropInName}.text == expectedDropIn;
assert !(builtins.hasAttr dropInName other.xdg.configFile);
assert !(builtins.hasAttr dropInName workstation.xdg.configFile);
assert !(builtins.elem runtime.azure-cli vm.home.packages);
assert !(builtins.elem runtime.ffmpeg vm.home.packages);
assert !(builtins.elem runtime.npm vm.home.packages);
assert builtins.elem socket (environment vm);
assert builtins.elem "FULCRUM_DESKTOP_PORT=3102" (environment vm);
assert builtins.elem "FULCRUM_HOST=0.0.0.0" (environment vm);
assert builtins.elem "FULCRUM_PORT=3100" (environment vm);
assert !(builtins.elem socket (environment other));
assert !(builtins.elem socket (environment workstation));
assert vm.systemd.user.services.fulcrum.Service.RuntimeDirectory == "fulcrum-desktop";
assert vm.systemd.user.services.fulcrum.Service.RuntimeDirectoryMode == "0700";
assert !(other.systemd.user.services.fulcrum.Service ? RuntimeDirectory);
assert builtins.elem pkgs.hello vm.home.packages;
assert !(builtins.elem pkgs.hello disabled.home.packages);
assert !(builtins.tryEval (builtins.deepSeq wrongHost.home.packages true)).success;
{
  hostScopedPrivateBootstrap = true;
  scopedRuntimeTools = true;
  fixedAzureHttpRuntime = true;
  supportedAzureBasePreserved = true;
  privateNpmReplacement = true;
  effectiveRuntimePath = true;
  browserListenerUnchanged = true;
  optionalPackage = true;
  unverifiedHostRejected = true;
}
