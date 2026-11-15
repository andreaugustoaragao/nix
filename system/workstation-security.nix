{
  config,
  lib,
  owner,
  ...
}:
let
  sudo = config.security.sudo;
  passwordRequired = command: !(builtins.isAttrs command && builtins.elem "NOPASSWD" command.options);
in
{
  systemd = {
    sockets.docker = {
      # NixOS leaves active sockets open; tmpfiles applies permissions immediately.
      socketConfig = {
        SocketMode = lib.mkForce "0600";
        SocketGroup = lib.mkForce "root";
      };
    };
    tmpfiles.rules = [
      "z /run/docker.sock 0600 root root -"
    ];
    user.services.docker.serviceConfig.LimitCORE = lib.mkForce 0;
  };

  assertions = [
    {
      assertion =
        sudo.wheelNeedsPassword
        && !(lib.hasInfix "NOPASSWD" sudo.extraConfig)
        && !(lib.hasInfix "!authenticate" sudo.extraConfig)
        && lib.all (rule: lib.all passwordRequired rule.commands) sudo.extraRules;
      message = "Workstation sudo must require authentication; passwordless rules are prohibited.";
    }
    {
      assertion = !config.system.autoUpgrade.enable;
      message = "Workstation system activation requires an authenticated operator, including remote Git updates.";
    }
    {
      assertion = !(builtins.elem "docker" config.users.users.${owner.name}.extraGroups);
      message = "Workstation development uses rootless Docker; the desktop user must not control the rootful socket.";
    }
  ];
}
