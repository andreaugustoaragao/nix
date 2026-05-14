{ owner, ... }:

let
  avatar = builtins.path {
    name = "aragao-avatar.png";
    path = ./assets/aragao-avatar.png;
  };
in
{
  # AccountsService — D-Bus interface for user account metadata (avatars,
  # full names, etc.). DMS uses it to persist profile edits made from the
  # in-app settings panel.
  services.accounts-daemon.enable = true;

  # Declarative profile avatar. AccountsService reads /var/lib/AccountsService/
  # icons/<user> and exposes it via D-Bus; DMS picks it up from there. C+
  # clears the destination first so the image refreshes whenever the source
  # store-path changes.
  systemd.tmpfiles.settings."10-accounts-avatar"."/var/lib/AccountsService/icons/${owner.name}"."C+" = {
    argument = avatar;
    user = "root";
    group = "root";
    mode = "0644";
  };
}
