{ ... }:

{
  # AccountsService — D-Bus interface for user account metadata (avatars,
  # full names, etc.). DMS uses it to persist profile edits made from the
  # in-app settings panel.
  services.accounts-daemon.enable = true;
}
