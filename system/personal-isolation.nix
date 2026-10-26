{
  config,
  lib,
  owner,
  personalOnly,
  isWorkMachine,
  ...
}:

{
  config = lib.mkIf personalOnly {
    # Bootstrap passwords are set interactively in the installer. Never
    # enroll this host as a recipient of the mixed work/personal secrets file.
    users.mutableUsers = true;
    services.openssh.enable = false;
    services.timesyncd.enable = true;

    assertions = [
      {
        assertion = !isWorkMachine;
        message = "A personal-only host cannot also be a work machine.";
      }
      {
        assertion = !config.hardware.parallels.enable;
        message = "Personal-only guests must not enable Parallels Tools' automatic host sharing.";
      }
      {
        assertion = config.sops.secrets == { };
        message = "Personal-only bootstrap must not import the shared SOPS secrets; use a separately encrypted personal store in a future enrollment.";
      }
      {
        assertion = config.security.pki.certificateFiles == [ ];
        message = "Personal-only hosts must not import the fleet's corporate or development CAs.";
      }
      {
        assertion = config.users.users.${owner.name}.openssh.authorizedKeys.keys == [ ];
        message = "Personal-only hosts must not inherit automatic access from fleet SSH keys.";
      }
      {
        assertion = !config.services.k3s.enable && config.virtualisation.docker.rootless.enable;
        message = "Personal development uses rootless Docker and no automatic work Kubernetes cluster.";
      }
    ];
  };
}
