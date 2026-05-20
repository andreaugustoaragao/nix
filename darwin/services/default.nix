{ ... }:

# Long-running daemons on mac-work that prl-dev-vm talks to over the
# Parallels shared network via mDNS (`mac-work.local`). Both run as
# user-scope LaunchAgents so they come up with the desktop session
# and can keep model files inside the logged-in user's home — mirrors
# the workstation pattern where `local-llm.service` is a systemd
# --user unit, not a system service.
#
# Network exposure: both daemons bind to 10.211.55.1 (the Parallels
# Shared-network host stub IP — the same address prl-dev-vm uses as
# its default gateway, see system/networking.nix). That interface only
# exists on the Mac↔Parallels bridge; hostile peers on public Wi-Fi
# have no route to it, so the daemons are unreachable from any network
# this laptop attaches to. No pf rules, no ALF prompts.
#
# vmw-dev-vm uses VMware Fusion's vmnet8 NAT (192.168.x.1) which
# varies per install — out of scope here. Adding it would mean either
# running a second pair of daemons on the VMware host IP, or fronting
# both with a small proxy that binds to both interfaces.

{
  imports = [
    ./local-llm.nix
    ./whisper-server.nix
  ];
}
