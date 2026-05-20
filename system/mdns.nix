{ hostName, ... }:

# mDNS (Bonjour) — every NixOS host in this flake announces and
# resolves `<hostname>.local` on its LAN segments. This is what makes
# `ssh prl-dev-vm.local` work from the Mac without chasing DHCP
# leases, and what lets printers / other peers discover each other.
#
# The avahi block lived in system/printing.nix previously, but only
# enabled name *resolution* (nssmdns4) — not *publishing* — so peers
# could find printers but the host itself never advertised. Splitting
# avahi out and turning publishing on fixes that.

let
  # Per-host mDNS interface whitelist. By default avahi publishes on
  # every interface it can see, which on hosts that bring up Docker /
  # k3s / podman bridges causes a recurring self-collision: a probe
  # sent on the real LAN NIC echoes back through the container/overlay
  # networks (docker0, cni0, flannel.1, …), avahi treats that as a
  # competing host claiming the name, and renumbers itself to
  # `<hostname>-N.local`. Every container churn or snapshot revert
  # bumps the suffix. By generation 9 the bare name is unreachable.
  #
  # Restrict each host to its single "real" LAN-facing NIC. Hosts not
  # listed here fall through to avahi's default (all-interfaces),
  # which is fine for machines without container/overlay networks.
  perHostInterfaces = {
    # Parallels Desktop paravirtualized NIC on Apple Silicon.
    prl-dev-vm = [ "enp0s5" ];
    # VMware Fusion vmxnet3 under modern systemd predictable naming.
    # If a future kernel/initrd uses a different name (ens33, ens192,
    # eth0, …) update this entry to match `ip -o link` output.
    vmw-dev-vm = [ "ens160" ];
  };
in
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

    # `null` means "all interfaces" (avahi default). For hosts in the
    # per-host map above, restrict explicitly so probe echoes via
    # container bridges can't trigger spurious collisions.
    allowInterfaces = perHostInterfaces.${hostName} or null;
  };
}
