# NixOS Security Audit Report
**Date:** February 10, 2026
**System:** NixOS 25.11 (Xantusia)
**Hostname:** prl-dev-vm
**Auditor:** Claude Code Security Analysis

---

## 🔴 CRITICAL VULNERABILITIES

### 1. SSH Password Authentication Enabled
**Location:** `/home/aragao/projects/personal/nix/system/ssh.nix:7`
**Risk:** Brute force attacks, credential stuffing
**Recommendation:**
```nix
settings = {
  PasswordAuthentication = false;  # Disable password auth
  KbdInteractiveAuthentication = false;
  PermitRootLogin = "no";
  PubkeyAuthentication = true;
}
```

### 2. Boot Partition World-Readable
**Issue:** `/boot` has permissions `drwxr-xr-x` and random seed file is world-accessible
**Risk:** Information disclosure, boot manipulation
**Recommendation:** Add to your NixOS configuration:
```nix
boot.loader.systemd-boot.configurationLimit = 10;
security.protectKernelImage = true;
```
Then run: `sudo chmod 700 /boot`

### 3. No Firewall Configuration
**Issue:** No explicit firewall rules, relying only on k3s/docker iptables
**Risk:** Unnecessary port exposure
**Recommendation:** Add to `system/networking.nix`:
```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 22 ];  # Only SSH
  allowedUDPPorts = [ ];
  # Allow k3s
  trustedInterfaces = [ "docker0" "cni0" ];
};
```

---

## 🟠 HIGH PRIORITY

### 4. No Intrusion Detection/Prevention
**Issue:** fail2ban not installed
**Recommendation:** Add to system configuration:
```nix
services.fail2ban = {
  enable = true;
  maxretry = 3;
  bantime = "24h";
  jails.sshd = ''
    enabled = true
    port = 22
  '';
};
```

### 5. No Mandatory Access Control (MAC)
**Issue:** No AppArmor or SELinux
**Recommendation:** Enable AppArmor:
```nix
security.apparmor = {
  enable = true;
  packages = [ pkgs.apparmor-profiles ];
};
```

### 6. Reverse Path Filtering Disabled
**Issue:** `net.ipv4.conf.all.rp_filter = 0`
**Risk:** IP spoofing attacks
**Recommendation:**
```nix
boot.kernel.sysctl = {
  "net.ipv4.conf.all.rp_filter" = 1;
  "net.ipv4.conf.default.rp_filter" = 1;
};
```

### 7. ICMP Redirects Enabled
**Issue:** `net.ipv4.conf.all.send_redirects = 1`
**Risk:** Man-in-the-middle attacks
**Recommendation:**
```nix
boot.kernel.sysctl = {
  "net.ipv4.conf.all.send_redirects" = 0;
  "net.ipv4.conf.default.send_redirects" = 0;
};
```

---

## 🟡 MEDIUM PRIORITY

### 8. User in Docker Group
**Issue:** User `aragao` in docker group (privilege escalation path)
**Risk:** Container escape = root access
**Recommendation:** If not actively using Docker, remove from group. Consider rootless Docker:
```nix
virtualisation.docker.rootless = {
  enable = true;
  setSocketVariable = true;
};
```

### 9. Passwordless Sudo for nixos-rebuild
**Location:** `system/users.nix:25`
**Risk:** Any process running as user can rebuild system
**Recommendation:** Consider requiring password or limit to specific terminal:
```nix
${owner.name} ALL=(ALL) PASSWD: /run/current-system/sw/bin/nixos-rebuild
```

### 10. SSH Port 22 Exposed
**Risk:** Constant scanning/attacks
**Recommendation:** Change SSH port:
```nix
services.openssh.ports = [ 2222 ];  # Non-standard port
```

### 11. No Audit Logging
**Issue:** auditd not running
**Recommendation:**
```nix
security.auditd.enable = true;
security.audit = {
  enable = true;
  rules = [
    "-a always,exit -F arch=b64 -S execve"
  ];
};
```

---

## 🔵 LOW PRIORITY / HARDENING

### 12. Additional Kernel Hardening
```nix
boot.kernel.sysctl = {
  # Existing good settings (keep these):
  "kernel.dmesg_restrict" = 1;
  "kernel.kptr_restrict" = 2;  # Increase from 1
  "kernel.yama.ptrace_scope" = 2;  # Increase from 1

  # Add these:
  "kernel.unprivileged_bpf_disabled" = 1;
  "kernel.unprivileged_userns_clone" = 0;
  "net.ipv4.tcp_timestamps" = 0;
  "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
  "net.ipv6.conf.all.accept_redirects" = 0;
  "net.ipv6.conf.default.accept_redirects" = 0;
};
```

### 13. Restrict K3s/Ollama Exposure
**Issue:** Services running on 0.0.0.0 or exposed to network
**Recommendation:** Ensure Ollama only listens on localhost (appears correct). Consider k3s firewall rules.

### 14. Enable Automatic Security Updates
**Status:** auto-upgrade.timer exists but verify it includes security updates
```nix
system.autoUpgrade = {
  enable = true;
  allowReboot = false;
  dates = "02:00";
  flake = "/home/aragao/projects/personal/nix";
};
```

### 15. Docker Container Cleanup
**Issue:** Old stopped containers (kafka, zookeeper)
```bash
docker system prune -a --volumes
```

### 16. Secure Shared Memory
```nix
boot.tmp.useTmpfs = true;
security.forcePageTableIsolation = true;
```

### 17. Harden SSH Further
```nix
services.openssh.settings = {
  # Add to existing config:
  MaxAuthTries = 3;
  ClientAliveInterval = 300;
  ClientAliveCountMax = 2;
  AllowUsers = [ "aragao" ];
  X11Forwarding = false;
  AllowTcpForwarding = false;
  AllowStreamLocalForwarding = false;
  GatewayPorts = false;
};
```

---

## ✅ SECURITY STRENGTHS FOUND

1. SOPS for secrets management with proper permissions
2. PermitRootLogin disabled
3. Protected hardlinks/symlinks enabled
4. TCP SYN cookies enabled
5. YESCRYPT password encryption
6. Auto-upgrade timer configured
7. systemd-resolved for DNS security

---

## 📋 IMMEDIATE ACTION PLAN

1. **Today:** Disable SSH password authentication
2. **Today:** Configure firewall with explicit rules
3. **Today:** Fix /boot permissions
4. **This Week:** Install and configure fail2ban
5. **This Week:** Enable AppArmor
6. **This Week:** Apply kernel hardening sysctls
7. **This Week:** Enable audit logging
8. **This Month:** Consider rootless Docker
9. **This Month:** Implement additional SSH hardening

---

## 🔧 Sample Complete Security Configuration

Create `/home/aragao/projects/personal/nix/system/security.nix`:

```nix
{ config, pkgs, lib, ... }:
{
  security = {
    apparmor.enable = true;
    auditd.enable = true;
    audit.enable = true;
    protectKernelImage = true;
    forcePageTableIsolation = true;
  };

  services.fail2ban = {
    enable = true;
    maxretry = 3;
    bantime = "24h";
  };

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.all.send_redirects" = 0;
    "kernel.kptr_restrict" = 2;
    "kernel.yama.ptrace_scope" = 2;
    "kernel.unprivileged_bpf_disabled" = 1;
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    trustedInterfaces = [ "docker0" ];
  };
}
```

Then add to `system/default.nix` imports: `./security.nix`

---

## 📊 SUMMARY

**Total Issues Found:** 17
- 🔴 Critical: 3
- 🟠 High: 4
- 🟡 Medium: 4
- 🔵 Low: 4
- ✅ Strengths: 7

**Security Score:** 6/10 (Good foundation, needs hardening)

---

## 🔍 SCAN DETAILS

### System Information
- **OS:** NixOS 25.11 (Xantusia)
- **Kernel:** 6.18.9
- **Architecture:** x86_64
- **Hostname:** prl-dev-vm
- **User:** aragao (uid=1000)

### Active Services
- SSH (port 22)
- Docker
- K3s (Kubernetes)
- Ollama (localhost:11434)
- systemd-resolved

### Network Configuration
- Interface: enp0s5 (10.211.55.31)
- DHCP: enabled
- IPv6: enabled
- Firewall: iptables (k3s/docker managed)

### Security Modules Status
- AppArmor: ❌ Not enabled
- SELinux: ❌ Not enabled
- fail2ban: ❌ Not installed
- auditd: ❌ Not running

---

**End of Report**
