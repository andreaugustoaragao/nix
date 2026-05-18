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

    # avahi/mDNS now lives in system/mdns.nix (imported unconditionally
    # by system/default.nix). CUPS + IPP printer discovery still works
    # because the daemon's still running — just owned by the more
    # general module.

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
