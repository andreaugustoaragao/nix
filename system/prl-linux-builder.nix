{
  lib,
  hostName,
  ...
}:

# Hardened untrusted remote Nix builder endpoint on prl-dev-vm for mac-work.
#
# Mirrors system/build-worker/default.nix:
#   - Dedicated `nix-ssh` account via `nix.sshServe` (`trusted = false`,
#     forced `nix-daemon --stdio` command — never grants an interactive shell
#     and never puts the interactive `aragao` user in `trusted-users`).
#   - Uses prl-dev-vm's existing Nix store signing key managed by
#     system/workstation-build-client.nix (`secrets/workers/clients/cache-prl-dev-vm.pub`)
#     to sign built outputs returned to mac-work.
#   - Trusts mac-work's builder-client signing public key so mac-work can copy
#     local source trees (e.g. during `nix flake check`) into this store
#     without needing `trusted = true`.

let
  clientSshPub = ../secrets/prl-builder/mac-work-ssh.pub;
  clientCachePub = ../secrets/prl-builder/mac-work-cache.pub;
  ready = builtins.pathExists clientSshPub && builtins.pathExists clientCachePub;
in
{
  config = lib.mkIf (hostName == "prl-dev-vm" && ready) {
    nix = {
      settings = {
        trusted-public-keys = [ (lib.trim (lib.fileContents clientCachePub)) ];
      };
      sshServe = {
        enable = true;
        write = true;
        trusted = false;
        protocol = "ssh-ng";
        keys = [ (lib.trim (lib.fileContents clientSshPub)) ];
      };
    };

    services.openssh.settings.AllowUsers = lib.mkAfter [ "nix-ssh" ];
  };
}
