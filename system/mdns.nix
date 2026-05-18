{ ... }:

# mDNS (Bonjour) — every NixOS host in this flake announces and
# resolves `<hostname>.local` on its LAN segments. This is what makes
# `ssh prl-dev-vm.local` work from the Mac without chasing DHCP
# leases, and what lets printers / other peers discover each other.
#
# The avahi block lived in system/printing.nix previously, but only
# enabled name *resolution* (nssmdns4) — not *publishing* — so peers
# could find printers but the host itself never advertised. Splitting
# avahi out and turning publishing on fixes that.

{
  services.avahi = {
    enable = true;

    # /etc/nsswitch.conf integration so `getent hosts foo.local` and
    # everything that uses libc resolution (ssh, curl, ping) sees
    # mDNS names automatically.
    nssmdns4 = true;

    # Punch UDP 5353 + the dynamic port range avahi uses for queries.
    # Without this, replies arrive after the firewall has dropped the
    # peer state and lookups time out intermittently.
    openFirewall = true;

    # Actively advertise this host on the LAN.
    publish = {
      enable = true;
      # Publish A/AAAA records so peers can resolve `<hostname>.local`.
      addresses = true;
      # Announce ourselves as a workstation (_workstation._tcp service)
      # so Finder's network browser, mDNS-aware schedulers, etc. see us.
      workstation = true;
    };
  };
}
