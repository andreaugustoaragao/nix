# Complete SOPS Secret Management Setup Guide

This guide will walk you through setting up a complete secret management system from scratch, including cleaning any existing keys and creating new ones.

## 🧹 Phase 1: Clean Existing Keys (START HERE)

### Step 1.1: Clean GPG Keys
```bash
# List existing GPG keys
gpg --list-keys
gpg --list-secret-keys

# Delete all existing GPG keys - batch deletion often fails, so use nuclear option:
# Alternative: Nuclear option - delete entire GPG directory (RECOMMENDED)
rm -rf ~/.gnupg

# Manual option (if you prefer to delete individual keys):
# For each key ID found from the list commands above:
# gpg --delete-secret-keys KEY_ID
# gpg --delete-keys KEY_ID
```

### Step 1.2: Clean SSH Keys
```bash
# Backup existing SSH config (just in case)
cp ~/.ssh/config ~/.ssh/config.backup 2>/dev/null || true

# List existing SSH keys
ls -la ~/.ssh/

# Remove all existing SSH keys (be careful!)
rm -f ~/.ssh/id_* 
rm -f ~/.ssh/*.pub
rm -f ~/.ssh/known_hosts*

# Clean SSH agent
ssh-add -D 2>/dev/null || true
```

### Step 1.3: Clean GPG Agent
```bash
# Kill existing GPG agent
pkill gpg-agent 2>/dev/null || true
gpgconf --kill all 2>/dev/null || true
```

## 🔑 Phase 2: Generate New Age Key for SOPS

### Step 2.1: Generate Age Key
```bash
# Generate the age key for sops encryption/decryption
age-keygen -o ~/.ssh/id_ed25519_nixos-agenix

# Display the public key - COPY THIS FOR NEXT STEP
echo "=== YOUR AGE PUBLIC KEY (COPY THIS) ==="
grep "^age1" ~/.ssh/id_ed25519_nixos-agenix
echo "======================================="

# Set proper permissions
chmod 600 ~/.ssh/id_ed25519_nixos-agenix
```

### Step 2.2: Create SOPS Configuration
```bash
# Navigate to your nix config directory
cd /home/aragao/projects/personal/nix

# Create .sops.yaml (replace YOUR_AGE_PUBLIC_KEY with the key from above)
cat > .sops.yaml << 'EOF'
keys:
  - &admin_key YOUR_AGE_PUBLIC_KEY_HERE

creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *admin_key
EOF

# IMPORTANT: Edit .sops.yaml and replace YOUR_AGE_PUBLIC_KEY_HERE with your actual key
nano .sops.yaml
```

## 🔐 Phase 3: Generate SSH Keys for GitHub

### Step 3.1: Generate Personal GitHub SSH Key
```bash
# Generate personal SSH key
ssh-keygen -t ed25519 -C "your-personal-email@example.com" -f ~/.ssh/id_ed25519_personal_temp

# Move to expected location (sops will place it here)
mv ~/.ssh/id_ed25519_personal_temp ~/.ssh/id_rsa_personal
mv ~/.ssh/id_ed25519_personal_temp.pub ~/.ssh/id_rsa_personal.pub

# Set proper permissions
chmod 600 ~/.ssh/id_rsa_personal
chmod 644 ~/.ssh/id_rsa_personal.pub
```

### Step 3.2: Generate Work GitHub SSH Key  
```bash
# Generate work SSH key
ssh-keygen -t ed25519 -C "your-work-email@company.com" -f ~/.ssh/id_ed25519_work_temp

# Move to expected location  
mv ~/.ssh/id_ed25519_work_temp ~/.ssh/id_rsa_work
mv ~/.ssh/id_ed25519_work_temp.pub ~/.ssh/id_rsa_work.pub

# Set proper permissions
chmod 600 ~/.ssh/id_rsa_work
chmod 644 ~/.ssh/id_rsa_work.pub
```

### Step 3.3: Add SSH Keys to GitHub
```bash
# Display personal public key - ADD THIS TO GITHUB PERSONAL ACCOUNT
echo "=== PERSONAL GITHUB SSH KEY (copy to GitHub Personal) ==="
cat ~/.ssh/id_rsa_personal.pub
echo

# Display work public key - ADD THIS TO GITHUB WORK ACCOUNT  
echo "=== WORK GITHUB SSH KEY (copy to GitHub Work) ==="
cat ~/.ssh/id_rsa_work.pub
echo
```

**GitHub Setup:**
1. **Personal Account**: Go to GitHub → Settings → SSH Keys → Add the personal key
2. **Work Account**: Go to GitHub → Settings → SSH Keys → Add the work key

## 🔒 Phase 4: Generate GPG Keys

### Step 4.1: Generate Personal GPG Key
```bash
# Generate personal GPG key (interactive)
gpg --full-generate-key

# Choose:
# 1. RSA and RSA (default)
# 2. 4096 (key size)
# 3. 0 (does not expire) or set expiration
# 4. Enter your personal name and email
# 5. Set a strong passphrase
```

### Step 4.2: Generate Work GPG Key
```bash
# Generate work GPG key (interactive)  
gpg --full-generate-key

# Choose:
# 1. RSA and RSA (default)
# 2. 4096 (key size) 
# 3. 0 (does not expire) or set expiration
# 4. Enter your work name and work email
# 5. Set a strong passphrase
```

### Step 4.3: Export GPG Keys
```bash
# List your GPG keys to get the key IDs
gpg --list-secret-keys

# Export personal GPG key (replace PERSONAL_KEY_ID)
gpg --export-secret-keys PERSONAL_KEY_ID > ~/.ssh/gpg_personal_temp.key

# Export work GPG key (replace WORK_KEY_ID)  
gpg --export-secret-keys WORK_KEY_ID > ~/.ssh/gpg_work_temp.key
```

## 🔐 Phase 5: Create Encrypted Secrets

### Step 5.1: Edit Secrets File
```bash
cd /home/aragao/projects/personal/nix

# Edit the secrets file with sops
sops secrets/secrets.yaml
```

**In the sops editor, replace the placeholder values:**

```yaml
# Generate password hashes first:
# Personal password: mkpasswd -m SHA-512
# Root password: mkpasswd -m SHA-512

user_password: "$6$YOUR_HASHED_PASSWORD_HERE"
root_password: "$6$YOUR_HASHED_ROOT_PASSWORD_HERE"

# Copy the private SSH key contents (paste the entire key including BEGIN/END lines):
ssh_key_github_work: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  [paste entire content of ~/.ssh/id_rsa_work here]
  -----END OPENSSH PRIVATE KEY-----

ssh_key_github_personal: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  [paste entire content of ~/.ssh/id_rsa_personal here]  
  -----END OPENSSH PRIVATE KEY-----

# Copy the public SSH key contents:
ssh_pubkey_github_work: "ssh-ed25519 AAAA... your-work-email@company.com"
ssh_pubkey_github_personal: "ssh-ed25519 AAAA... your-personal-email@example.com"

# Copy the GPG key contents:
gpg_key_personal: |
  -----BEGIN PGP PRIVATE KEY BLOCK-----
  [paste entire content of ~/.ssh/gpg_personal_temp.key here]
  -----END PGP PRIVATE KEY BLOCK-----

gpg_key_work: |
  -----BEGIN PGP PRIVATE KEY BLOCK-----
  [paste entire content of ~/.ssh/gpg_work_temp.key here]
  -----END PGP PRIVATE KEY BLOCK-----
```

**Important:** 
- Save and exit sops editor (Ctrl+X in nano, :wq in vim)
- The file will be automatically encrypted when you save

### Step 5.2: Generate Password Hashes
```bash
# Generate password hash for your user (you'll be prompted for password)
mkpasswd -m SHA-512

# Generate password hash for root (you'll be prompted for password)  
mkpasswd -m SHA-512

# Copy these hashes to use in the secrets.yaml file above
```

## 🔧 Phase 6: Activate the Configuration

### Step 6.1: Update SOPS Configuration
```bash
cd /home/aragao/projects/personal/nix

# Enable sops file validation now that we have real secrets
nano system/sops.nix

# Change this line:
# validateSopsFiles = false;
# To:
# validateSopsFiles = true;
```

### Step 6.2: Add to Git and Rebuild
```bash
# Add new files to git (the encrypted secrets.yaml is safe to commit)
git add .sops.yaml secrets/secrets.yaml system/sops.nix

# The auto-rebuild should pick this up, or manually rebuild:
sudo nixos-rebuild switch --flake .#parallels-nixos
```

### Step 6.3: Test SSH Access
```bash
# Test personal GitHub access
ssh -T github-personal

# Test work GitHub access  
ssh -T github-work

# Both should respond with: "Hi username! You've successfully authenticated..."
```

## 🧹 Phase 7: Clean Temporary Files

### Step 7.1: Remove Temporary Key Files
```bash
# Remove temporary GPG exports (they're now encrypted in sops)
rm -f ~/.ssh/gpg_*_temp.key

# Remove the original SSH keys (they're now managed by sops)
rm -f ~/.ssh/id_rsa_personal ~/.ssh/id_rsa_personal.pub
rm -f ~/.ssh/id_rsa_work ~/.ssh/id_rsa_work.pub

# The sops system will recreate them in the proper locations
```

## ✅ Phase 8: Verification

### Step 8.1: Verify Secret Paths
```bash
# Check that sops secrets are mounted
ls -la /run/secrets/

# Should show:
# gpg_key_personal
# gpg_key_work  
# ssh_key_github_personal
# ssh_key_github_work
# ssh_pubkey_github_personal
# ssh_pubkey_github_work
# user_password
# root_password
```

### Step 8.2: Verify SSH Keys Are Loaded
```bash
# SSH keys should now be at the sops-managed locations
ls -la ~/.ssh/id_rsa_*

# Test GitHub access again
ssh -T github-personal
ssh -T github-work
```

### Step 8.3: Verify GPG Keys Are Imported
```bash
# Check GPG keys are imported
gpg --list-keys
gpg --list-secret-keys

# Should show both your personal and work GPG keys
```

## 🎉 Phase 9: Enable Password Authentication (Optional)

### Step 9.1: Uncomment Password Configuration
```bash
# Edit the sops configuration to enable password management
nano system/sops.nix

# Uncomment these lines:
# users.users.${owner.name} = {
#   hashedPasswordFile = config.sops.secrets.user_password.path;
# };

# users.users.root = {
#   hashedPasswordFile = config.sops.secrets.root_password.path;  
# };

# Rebuild to apply password changes
sudo nixos-rebuild switch --flake .#parallels-nixos
```

## 🔄 Usage Examples

### Git Repository Configuration
```bash
# Clone personal repository
git clone git@github-personal:username/personal-repo.git

# Clone work repository  
git clone git@github-work:company/work-repo.git

# Set git config for signing (use appropriate GPG key)
git config --global user.signingkey PERSONAL_GPG_KEY_ID
git config --global commit.gpgsign true
```

### Multi-Machine Deployment
```bash
# On your workstation:
sudo nixos-rebuild switch --flake .#workstation

# On your HP laptop:
sudo nixos-rebuild switch --flake .#hp-laptop
```

## 🆘 Troubleshooting

### GPG Agent Issues
```bash
# Restart GPG agent
gpgconf --kill all
gpg-connect-agent /bye
```

### SSH Issues  
```bash
# Clear SSH agent and reload
ssh-add -D
ssh-add ~/.ssh/id_rsa_personal ~/.ssh/id_rsa_work
```

### SOPS Issues
```bash
# Re-encrypt secrets file
sops updatekeys secrets/secrets.yaml

# Check sops can decrypt
sops -d secrets/secrets.yaml
```

---

## 📋 Quick Reference

**SSH Hosts:**
- Personal: `git@github-personal:username/repo.git`
- Work: `git@github-work:company/repo.git`

**Key Locations:**
- Age key: `~/.ssh/id_ed25519_nixos-agenix`
- SSH keys: `~/.ssh/id_rsa_personal`, `~/.ssh/id_rsa_work` (managed by sops)
- GPG keys: Auto-imported to GPG keyring from sops

**Important Files:**
- `.sops.yaml` - SOPS configuration
- `secrets/secrets.yaml` - Encrypted secrets
- `system/sops.nix` - NixOS sops configuration

Your complete secret management system is now operational! 🎉