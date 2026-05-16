{ pkgs, ... }:

{
  services = {
    printing = {
      enable = true;
      webInterface = true;
      drivers = with pkgs; [
        gutenprint
        hplip
      ];
    };

    # mDNS for auto-discovering network printers (Bonjour / IPP).
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    # cups-pk-helper exposes printer admin (add/remove/configure) via the
    # D-Bus / polkit interface DankMaterialShell talks to.
    dbus.packages = [ pkgs.cups-pk-helper ];
  };

  hardware = {
    printers = {
      ensurePrinters = [
        {
          name = "HP_OfficeJet_3830";
          description = "HP OfficeJet 3830 series";
          location = "Home";
          deviceUri = "socket://192.168.20.74:9100";
          model = "drv:///hp/hpcups.drv/hp-officejet_3830_series.ppd";
        }
      ];
      ensureDefaultPrinter = "HP_OfficeJet_3830";
    };

    # OfficeJet devices are multifunction printers; this enables SANE's HP
    # backend for scanning once the device is reachable.
    sane = {
      enable = true;
      extraBackends = [ pkgs.hplip ];
    };
  };

  # HP setup/debugging tools (`hp-setup`, `hp-makeuri`, `hp-info`) are useful
  # when a network printer does not advertise itself via mDNS.
  environment.systemPackages = with pkgs; [
    hplip
    system-config-printer
  ];

}
