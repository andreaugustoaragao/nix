{ ... }:

# Long-running daemons on mac-work that prl-dev-vm talks to over the
# Parallels shared network via mDNS (`mac-work.local`). They run as
# user-scope LaunchAgents so they come up with the desktop session and
# can keep model files inside the logged-in user's home — mirrors the
# workstation pattern where `local-llm.service` is a systemd --user
# unit, not a system service.
#
# Network exposure: VM-facing services bind to 10.211.55.2, the Mac's
# bridge100 address. That interface only exists on the Mac↔Parallels
# bridge; hostile peers on public Wi-Fi have no route to it. The
# FluidAudio app stays on loopback and a dedicated proxy exposes only
# this bridge address.
#
# vmw-dev-vm uses VMware Fusion's vmnet8 NAT (192.168.x.1) which
# varies per install — out of scope here. Adding it would mean either
# running a second pair of daemons on the VMware host IP, or fronting
# both with a small proxy that binds to both interfaces.

{
  imports = [
    ./diarization-server.nix
    ./local-llm.nix
    ./whisper-server.nix
  ];
}
