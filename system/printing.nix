{ pkgs, ... }:

{
  services.printing = {
    enable = true;
    drivers = with pkgs; [
      gutenprint
      hplip
    ];
  };

  # mDNS for auto-discovering network printers (Bonjour / IPP).
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # cups-pk-helper exposes printer admin (add/remove/configure) via the
  # D-Bus / polkit interface DankMaterialShell talks to.
  environment.systemPackages = [ pkgs.cups-pk-helper ];
  services.dbus.packages = [ pkgs.cups-pk-helper ];
}
