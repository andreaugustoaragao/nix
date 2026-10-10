{ owner, lib, ... }:

{
  users.groups.k3s-admin = { };
  users.users.${owner.name} = {
    isNormalUser = true;
    description = owner.fullName;
    extraGroups = [
      "wheel"
      "k3s-admin"
    ];
    # Set a local password from the installer for authenticated sudo.
    # SSH keys work independently of the disabled initial password.
    initialHashedPassword = "!";
    openssh.authorizedKeys.keys = [
      # Existing desktop personal public key; its private key stays there.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECX5xCCeHXtKMa98SL3Z6ZLDVkQdLKD7hcywXNjlWcm andrearag@gmail.com"
      (lib.fileContents ../../secrets/ssh_pubkeys/mac-work_peers.pub)
    ];
  };
  users.users.root.initialHashedPassword = "!";

  security.sudo = {
    enable = true;
    wheelNeedsPassword = true;
    extraConfig = "Defaults timestamp_timeout=5";
  };

  services.openssh = {
    enable = true;
    openFirewall = false; # Source-restricted rules in networking.nix.
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ owner.name ];
      AllowAgentForwarding = false;
      AllowTcpForwarding = "no";
      AllowStreamLocalForwarding = "no";
      X11Forwarding = false;
      MaxAuthTries = 3;
    };
  };

  # Membership intentionally grants cluster-admin and effective root on
  # THIS VM. No credentials granting access back to the desktop are installed.
  environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  systemd.tmpfiles.rules = [
    "d /etc/rancher/k3s 0750 root k3s-admin -"
  ];
}
