{ pkgs, homeManager }:
let
  fixture =
    hostName: package:
    (homeManager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inherit hostName;
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
in
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
  browserListenerUnchanged = true;
  optionalPackage = true;
  unverifiedHostRejected = true;
}
