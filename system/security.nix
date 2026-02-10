{ config, pkgs, lib, ... }:

{
  # ============================================================================
  # NixOS Security Hardening Configuration
  # Addresses critical and high-priority security recommendations
  # Created: 2026-02-10
  # ============================================================================

  security = {
    # Mandatory Access Control via AppArmor
    apparmor = {
      enable = true;
      packages = [ pkgs.apparmor-profiles ];
      killUnconfinedConfinables = true;
    };

    # Audit system for security monitoring
    # Tuned for a NixOS dev machine: focus on privilege escalation,
    # persistence, and credential access — skip noisy execve/etc logging.
    auditd.enable = true;
    audit = {
      enable = true;
      rules = [
        # ── Privilege escalation ──
        "-w /run/wrappers/bin/sudo -p x -k priv_esc"
        "-w /run/wrappers/bin/su -p x -k priv_esc"
        "-a always,exit -F arch=b64 -S setuid -S setgid -S setreuid -S setregid -S setresuid -S setresgid -F auid>=1000 -F auid!=4294967295 -k priv_esc"

        # ── Kernel modules (rootkit loading) ──
        "-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k kernel_mod"

        # ── Mount operations (data exfil, overlay attacks) ──
        "-a always,exit -F arch=b64 -S mount -S umount2 -F auid>=1000 -F auid!=4294967295 -k mount"

        # ── Credential and secrets access ──
        "-w /etc/shadow -p wa -k credentials"
        "-w /etc/passwd -p wa -k credentials"
        "-w /etc/group -p wa -k credentials"
        "-w /run/secrets -p r -k secrets_access"

        # ── SSH config and keys ──
        "-w /etc/ssh -p wa -k ssh_config"

        # ── Time tampering (log evasion) ──
        "-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S clock_settime -k time_change"

        # ── Audit config tampering ──
        "-w /var/log/audit -p wa -k audit_log_tamper"
        "-w /etc/audit -p wa -k audit_config"

        # ── Make rules immutable until reboot (must be last) ──
        "-e 2"
      ];
    };

    # Protect kernel image from modification
    protectKernelImage = true;

    # Force page table isolation (Meltdown mitigation)
    forcePageTableIsolation = true;

    # Real-time kit is already enabled, keep it
    rtkit.enable = true;

    # Polkit is already enabled, keep it
    polkit.enable = true;
  };

  # ============================================================================
  # Intrusion Detection and Prevention
  # ============================================================================

  services.fail2ban = {
    enable = true;
    maxretry = 3;
    bantime = "24h";
    bantime-increment = {
      enable = true;
      multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h"; # 1 week max
      overalljails = true;
    };

    # Whitelist localhost
    ignoreIP = [
      "127.0.0.0/8"
      "::1"
    ];

    # SSH protection is automatically enabled by NixOS
    # The sshd jail is configured by default when fail2ban is enabled
  };

  # ============================================================================
  # Kernel Hardening Parameters
  # ============================================================================

  boot.kernel.sysctl = {
    # -------------------------
    # Kernel Security
    # -------------------------
    # Restrict dmesg access (already set, keeping it)
    "kernel.dmesg_restrict" = 1;

    # Hide kernel pointers in /proc
    "kernel.kptr_restrict" = 2;

    # Restrict ptrace to parent processes only
    "kernel.yama.ptrace_scope" = 2;

    # Disable unprivileged BPF
    "kernel.unprivileged_bpf_disabled" = 1;

    # Note: kernel.unprivileged_userns_clone is a Debian-only patch,
    # not available on mainline kernels used by NixOS.

    # -------------------------
    # Network Security - IPv4
    # -------------------------
    # Enable reverse path filtering (anti-spoofing)
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;

    # Disable ICMP redirects (prevent MITM)
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;

    # Disable source packet routing
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;

    # Enable TCP SYN cookies (already enabled, keeping it)
    "net.ipv4.tcp_syncookies" = 1;

    # Disable TCP timestamps (privacy)
    "net.ipv4.tcp_timestamps" = 0;

    # Ignore ICMP broadcast requests
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;

    # Ignore bogus ICMP error responses
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

    # Log suspicious packets (martians)
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.conf.default.log_martians" = 1;

    # -------------------------
    # Network Security - IPv6
    # -------------------------
    # Note: IPv6 RA is managed by systemd-networkd in networking.nix
    # Uncomment these if you want to disable IPv6 RA globally:
    # "net.ipv6.conf.all.accept_ra" = 0;
    # "net.ipv6.conf.default.accept_ra" = 0;

    # Disable IPv6 redirects
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;

    # Disable IPv6 source routing
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.default.accept_source_route" = 0;

    # -------------------------
    # Filesystem Security
    # -------------------------
    # Protect hardlinks and symlinks (already enabled)
    "fs.protected_hardlinks" = 1;
    "fs.protected_symlinks" = 1;

    # Protect FIFOs and regular files
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
  };

  # ============================================================================
  # Secure Boot and Temporary Filesystems
  # ============================================================================

  boot = {
    # Use tmpfs for /tmp (cleared on reboot, performance boost)
    tmp.useTmpfs = true;
    tmp.tmpfsSize = "50%";

    # configurationLimit is set in boot.nix per machine profile

    # Clean /tmp on boot
    tmp.cleanOnBoot = true;
  };

  # ============================================================================
  # Additional System Hardening
  # ============================================================================

  # Disable core dumps (prevent information disclosure)
  systemd.coredump.enable = false;

  # Restrict /proc and /sys access
  boot.specialFileSystems = {
    "/proc".options = [ "hidepid=2" ];
  };

  # Enable kernel lockdown mode (requires recent kernel)
  # boot.kernelParams = [ "lockdown=integrity" ];
}
