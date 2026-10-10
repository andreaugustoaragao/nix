{ pkgs, hostConfig }:

let
  # Guard the separation from the desktop/server profiles. These checks
  # intentionally fail if a broad import starts bringing credentials or
  # host integration into the cluster VM.
  isolated =
    !(hostConfig ? sops)
    && !(hostConfig ? home-manager)
    && !hostConfig.hardware.parallels.enable
    && !hostConfig.virtualisation.docker.enable
    && !hostConfig.services.xserver.enable;
  authenticated =
    hostConfig.networking.firewall.enable
    && hostConfig.security.sudo.wheelNeedsPassword
    && !hostConfig.services.openssh.settings.PasswordAuthentication
    && !hostConfig.services.openssh.settings.AllowAgentForwarding
    && hostConfig.services.openssh.settings.PermitRootLogin == "no";
  fullClusterAdmin =
    hostConfig.services.k3s.enable
    && hostConfig.services.k3s.role == "server"
    && builtins.elem "k3s-admin" hostConfig.users.users.aragao.extraGroups
    && builtins.elem "--write-kubeconfig-mode=0640" hostConfig.services.k3s.extraFlags
    && builtins.elem "--write-kubeconfig-group=k3s-admin" hostConfig.services.k3s.extraFlags;
in
assert pkgs.lib.assertMsg isolated
  "The Kubernetes VM must not import desktop credentials or host sharing.";
assert pkgs.lib.assertMsg authenticated
  "The Kubernetes VM must retain authenticated remote access.";
assert pkgs.lib.assertMsg fullClusterAdmin
  "The cluster administrator must retain full Kubernetes access.";
pkgs.runCommand "check-kubernetes-vm" { } ''
  touch "$out"
''
