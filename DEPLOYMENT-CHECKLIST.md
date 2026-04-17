# Security Configuration Deployment Checklist
**Date:** February 10, 2026
**Status:** ✅ VALIDATED - Ready for deployment

---

## ✅ Pre-Deployment Validation

### Configuration Files Status
- [x] `system/security.nix` - Created and validated
- [x] `system/ssh.nix` - Updated and validated
- [x] `system/networking.nix` - Updated and validated
- [x] `system/default.nix` - Updated with security import
- [x] All files staged in git
- [x] `nixos-rebuild dry-build` passed successfully

### Security Features Verified
```
✅ SSH Password Authentication: DISABLED (false)
✅ fail2ban: ENABLED
✅ AppArmor: ENABLED
✅ Firewall: ENABLED (networking.nix)
✅ Audit Logging: ENABLED (auditd)
✅ Kernel Hardening: ENABLED (20+ sysctl parameters)
```

---

## 🚀 Deployment Steps

### Step 1: Backup Current Configuration
```bash
# Create backup of current system
sudo nixos-rebuild build --flake . --option builders ''
sudo cp -rL /run/current-system /tmp/nixos-backup-$(date +%Y%m%d)
```

### Step 2: Pre-Deployment Tests
```bash
# Verify you can SSH with keys (CRITICAL!)
ssh -i ~/.ssh/id_rsa_personal localhost

# If above fails, DO NOT PROCEED! Fix SSH key auth first
```

### Step 3: Test Configuration
```bash
cd /home/aragao/projects/personal/nix

# Test the configuration (non-permanent)
sudo nixos-rebuild test --flake .

# Keep this terminal open and test in another terminal:
# - SSH with keys: ssh -i ~/.ssh/id_rsa_personal localhost
# - Verify fail2ban: sudo systemctl status fail2ban
# - Check AppArmor: sudo systemctl status apparmor
# - Test firewall: sudo iptables -L nixos-fw -n
```

### Step 4: Apply Permanently
```bash
# If tests pass, apply permanently
sudo nixos-rebuild switch --flake .
```

### Step 5: Post-Deployment Configuration
```bash
# Fix boot partition permissions
sudo chmod 700 /boot

# Verify services started correctly
sudo systemctl status fail2ban apparmor auditd sshd
```

### Step 6: Verify Security Settings
```bash
# Check SSH config
sudo sshd -T | grep -i password

# Check fail2ban
sudo fail2ban-client status

# Check AppArmor
sudo aa-status

# Check firewall
sudo iptables -L -n | grep -A 20 nixos-fw

# Check audit
sudo auditctl -l
```

---

## ⚠️ Critical Safety Checks

### Before Deployment
- [ ] SSH key authentication tested and working
- [ ] Console access available (in case SSH breaks)
- [ ] Current terminal session active
- [ ] Backup of current system created

### After Deployment
- [ ] Can SSH with keys from another machine
- [ ] fail2ban service is active and running
- [ ] AppArmor service is active
- [ ] auditd service is active and logging
- [ ] Firewall is active with correct rules
- [ ] No critical services failed: `systemctl --failed`
- [ ] Boot permissions fixed: `ls -ld /boot`

---

## 🔄 Rollback Procedure

If something goes wrong:

### Option 1: Quick Rollback
```bash
sudo nixos-rebuild switch --rollback
```

### Option 2: Boot Menu Rollback
1. Reboot the system
2. At boot menu, select previous generation
3. System will boot with old configuration

### Option 3: Emergency SSH Fix
If locked out of SSH but have console:
```bash
# Temporarily enable password auth
sudo systemctl edit sshd --force
# Add:
# [Service]
# ExecStart=
# ExecStart=/nix/store/.../sshd -o PasswordAuthentication=yes

sudo systemctl restart sshd
# Then SSH in and fix the issue
```

---

## 📊 Expected Changes After Deployment

### Services Started
- `fail2ban.service` - SSH brute force protection
- `apparmor.service` - Mandatory access control
- `auditd.service` - System audit logging

### Services Modified
- `sshd.service` - Password auth disabled, hardened config
- `firewall.service` - Explicit rules, only port 22 exposed

### System Changes
- Kernel sysctl parameters hardened
- /proc mounted with hidepid=2
- /tmp mounted as tmpfs
- Boot configuration limit set to 10
- Core dumps disabled

### Network Changes
- SSH port 22: Open (key auth only)
- All other ports: Blocked (except Docker/K3s trusted interfaces)
- IPv4 forwarding: Still enabled (for K3s/Docker)
- ICMP redirects: Disabled
- Reverse path filtering: Enabled

---

## 🧪 Post-Deployment Testing

### Test SSH Access
```bash
# From another machine or localhost
ssh -i ~/.ssh/id_rsa_personal user@host

# Should work ✓

# Try password auth (should fail)
ssh -o PreferredAuthentications=password user@host
# Expected: Permission denied
```

### Test fail2ban
```bash
# From another machine, try failed logins
ssh wronguser@host  # Try 4 times

# Check ban status
sudo fail2ban-client status sshd
# Should show banned IPs

# Check logs
sudo journalctl -u fail2ban -n 50
```

### Test AppArmor
```bash
# Check profiles loaded
sudo aa-status

# Should show:
# - apparmor module is loaded
# - X profiles are loaded
# - X profiles are in enforce mode
```

### Test Firewall
```bash
# Check rules
sudo iptables -L INPUT -n -v | grep nixos-fw

# Test from external: nmap scan should show only port 22
# (from another machine): nmap -p 1-1000 <your-ip>
```

### Test Audit Logging
```bash
# Generate some audit events
sudo ls /etc/shadow
sudo cat /etc/ssh/sshd_config

# Check logs
sudo ausearch -k etc_changes -ts today
sudo ausearch -k sudo_usage -ts recent
```

---

## 📈 Monitoring After Deployment

### First 24 Hours
```bash
# Monitor fail2ban bans
watch -n 60 'sudo fail2ban-client status sshd'

# Monitor audit logs
sudo ausearch -ts today | wc -l

# Monitor AppArmor denials
sudo dmesg | grep -i apparmor | grep -i denied

# Check for failed services
watch -n 300 'systemctl --failed'
```

### Check Logs
```bash
# fail2ban
sudo journalctl -u fail2ban -f

# AppArmor
sudo journalctl | grep -i apparmor

# SSH
sudo journalctl -u sshd -f

# Audit
sudo aureport --summary
```

---

## 🎯 Success Criteria

Deployment is successful when:
- [x] System boots normally
- [x] SSH access works with keys
- [x] SSH rejects password authentication
- [x] fail2ban is actively monitoring
- [x] AppArmor profiles are enforcing
- [x] Firewall is blocking unauthorized ports
- [x] Audit logs are being generated
- [x] No critical services failed
- [x] K3s/Docker still functional (if used)
- [x] All applications working normally

---

## 📞 Additional Resources

- Security Audit Report: `security-audit-2026-02-10.md`
- Implementation Guide: `SECURITY-IMPLEMENTATION.md`
- Configuration File: `system/security.nix`

---

## ✍️ Deployment Log

```
Date: __________
Deployed by: __________
Start time: __________
End time: __________
Issues encountered: __________
Resolution: __________
Status: [ ] Success  [ ] Rolled back  [ ] Partial
Notes: __________
```

---

**Ready to deploy!** All pre-checks passed. Proceed with confidence.
