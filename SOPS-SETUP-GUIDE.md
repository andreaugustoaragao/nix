# SOPS Secret Management — Operations Guide

This guide describes how secrets are organized in this flake, how to
edit them day-to-day, and how to add a new machine to the recipient
list. The system is already operational; for a from-scratch fleet
rebuild see the appendix.

## 🏛 Architecture

```
.sops.yaml              # Recipient list (age public keys per host/user)
secrets/secrets.yaml    # Encrypted blob — single source of truth
system/sops.nix         # NixOS: where the host key lives + secret definitions
darwin/sops.nix         # nix-darwin: same, with macOS-shaped paths
home/cli/fish.nix       # `sops-edit` shell function (fish)
home/cli/zsh.nix        # `sops-edit` shell function (zsh)
```

### Where the age key lives, per platform

| Platform | Path                                       | Owner       | How it gets there                  |
| -------- | ------------------------------------------ | ----------- | ---------------------------------- |
| NixOS    | `/var/lib/sops-nix/key.txt`                | `root:root` | `sops-nix` auto-generates on first activation (`generateKey = true` in `system/sops.nix`) |
| macOS    | `~/.config/sops/age/keys.txt`              | user        | Created out-of-band with `age-keygen` (see "Add a macOS host" below) |

Consequence: on NixOS the key is **root-only**. To run `sops` as your
user you have to go through `sudo`. The `sops-edit` shell function
takes care of this transparently.

### Current recipients

`.sops.yaml` encrypts `secrets/secrets.yaml` to:

- `admin_key`        — your personal age identity (lives on the workstation)
- `tala_key`         — server host key
- `mac_work_key`     — macOS host key at `~/.config/sops/age/keys.txt`
- `prl_dev_vm_key`   — Parallels dev VM host key
- a small set of inline pubkeys for the other NixOS hosts (workstation, hp-laptop, vmw-dev-vm)

Any recipient can decrypt the file. Adding or removing recipients
requires re-encrypting (`sops updatekeys`).

## ✏️ Editing Secrets (the day-to-day workflow)

Use the `sops-edit` shell function. It handles the platform split for you.

```bash
cd /home/aragao/projects/personal/nix

# Edit (drops you into $EDITOR with decrypted YAML; re-encrypts on save)
sops-edit secrets/secrets.yaml

# Decrypt to stdout (read-only inspection)
sops-edit -d secrets/secrets.yaml

# Re-encrypt to the current recipient list (after changing .sops.yaml)
sops-edit updatekeys secrets/secrets.yaml
```

Under the hood:

- **On NixOS**: `sudo -E env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops "$@"`, then restore ownership of any file argument that ended up `root:root` afterwards.
- **On macOS**: plain `sops "$@"`. The user's age key at `~/.config/sops/age/keys.txt` is what sops finds by default.

After editing, commit and rebuild:

```bash
git add secrets/secrets.yaml
git commit -m "secrets: <what changed>"
sudo nixos-rebuild switch --flake .#$(hostname)        # NixOS
# or: darwin-rebuild switch --flake .#$(hostname -s)   # macOS
```

`sops-nix` writes the decrypted secrets to `/run/secrets/…` (NixOS)
or `/run/secrets/…` (macOS, via the darwin module) on activation.

## ➕ Add a New NixOS Host

1. **Provision the host** with a placeholder password and add it to
   `machines.toml`. Build it once normally:

   ```bash
   sudo nixos-rebuild switch --flake .#<new-host>
   ```

   The first activation will fail to *decrypt* the secrets (the new
   host isn't a recipient yet) but `sops-nix` runs the
   `generateKey` step first, so `/var/lib/sops-nix/key.txt` will
   exist after this.

2. **Read the new host's age pubkey** (on the new host, as root):

   ```bash
   sudo nix-shell -p age --run \
     'age-keygen -y /var/lib/sops-nix/key.txt'
   ```

   Copy the `age1…` line.

3. **Add it as a recipient** in `.sops.yaml` on any host that already
   has decryption access:

   ```yaml
   keys:
     - &new_host_key age1<paste>
   creation_rules:
     - path_regex: secrets/.*\.yaml$
       key_groups:
         - age:
             - *admin_key
             - *tala_key
             - *mac_work_key
             - *prl_dev_vm_key
             - *new_host_key   # ← here
   ```

4. **Re-encrypt** so the new host can read the file:

   ```bash
   sops-edit updatekeys secrets/secrets.yaml
   git add .sops.yaml secrets/secrets.yaml
   git commit -m "sops: add <new-host> as recipient"
   git push
   ```

5. **Pull and rebuild on the new host:**

   ```bash
   git pull
   sudo nixos-rebuild switch --flake .#<new-host>
   ```

   This time the activation decrypts cleanly and `/run/secrets/…`
   gets populated.

## ➕ Add a New macOS Host

1. **Generate a user-owned age key:**

   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt
   chmod 600 ~/.config/sops/age/keys.txt
   ```

2. **Get the pubkey:**

   ```bash
   age-keygen -y ~/.config/sops/age/keys.txt
   ```

3. **Add it to `.sops.yaml`** and `sops-edit updatekeys` (same as
   step 3–4 above for NixOS).

4. **Apply the darwin config:**

   ```bash
   darwin-rebuild switch --flake .#<new-host>
   ```

Note: the macOS module sets `sshKeyPaths = [ ]` and `generateKey = false`
in `darwin/sops.nix` — sops-nix expects the key to already exist at the
configured path. Don't skip step 1.

## 🔁 Rotating / Removing Recipients

Same flow as adding, but in reverse:

1. Edit `.sops.yaml` to remove or replace the recipient.
2. `sops-edit updatekeys secrets/secrets.yaml`
3. Commit and push.
4. Rebuild on any host you want to refresh.

To rotate the **host key** on a NixOS machine (compromise scenario):

```bash
sudo rm /var/lib/sops-nix/key.txt           # delete old key
sudo nixos-rebuild switch --flake .#$(hostname)   # sops-nix generates a new one
sudo age-keygen -y /var/lib/sops-nix/key.txt      # read the new pubkey
# → update .sops.yaml + sops-edit updatekeys + commit
```

After rotation any backup of `secrets.yaml` encrypted under the old
recipient is still readable by an attacker holding the old key — so
also rotate the *contents* of any secret you suspect was leaked.

## 🛠 Troubleshooting

### `failed to get the data key required to decrypt the SOPS file`

You don't have an age identity sops can find. On NixOS that's
expected for the user account — use `sops-edit` (which sudo's into
the host key). On macOS, check that `~/.config/sops/age/keys.txt`
exists and that its pubkey is one of the recipients in `.sops.yaml`.

### `File … already up to date` from `updatekeys`

Nothing to do — the file is already encrypted to the current
recipient set. Confirm with `sops -d secrets/secrets.yaml | head`.

### Activation succeeds but `/run/secrets/<foo>` is empty / missing

The secret isn't declared in `system/sops.nix` (or `darwin/sops.nix`).
sops-nix only materializes what's listed in `sops.secrets`. Add the
entry, rebuild.

### `validateSopsFiles` build failure

`secrets/secrets.yaml` isn't a valid sops envelope (e.g. you saved
it un-encrypted). Restore from git and re-edit via `sops-edit`.

### GPG signing prompts for passphrase every commit

The macOS Keychain caches it after the first `gpg --sign` (see
`home/cli/gpg-darwin.nix`). On Linux the cache TTL is set in
`gpg-agent.conf`; `pkill gpg-agent && gpgconf --launch gpg-agent`
forces a reload.

## 📋 Quick Reference

```bash
# Edit secrets (works on every machine)
sops-edit secrets/secrets.yaml

# Re-encrypt after recipient changes
sops-edit updatekeys secrets/secrets.yaml

# Read your own host's age pubkey
sudo age-keygen -y /var/lib/sops-nix/key.txt        # NixOS
age-keygen -y ~/.config/sops/age/keys.txt           # macOS

# Generate a password hash for user/root secrets
mkpasswd -m SHA-512
```

**Key files:**

- `.sops.yaml` — recipient list, single source of truth for who can decrypt
- `secrets/secrets.yaml` — encrypted blob, safe to commit
- `system/sops.nix` / `darwin/sops.nix` — secret declarations + output paths
- `home/cli/fish.nix` / `home/cli/zsh.nix` — `sops-edit` wrapper

---

## 🧱 Appendix: From-Scratch Fleet Bootstrap

Use this only if you're rebuilding the entire fleet from zero. For
adding a single machine to an existing fleet, follow the "Add a new
… host" sections above instead.

### A. Personal admin age key

This is the long-lived identity that survives any host being
reprovisioned. Generate once, keep it on a trusted machine, back it
up offline.

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt          # → admin pubkey
```

### B. `.sops.yaml` seed

```yaml
keys:
  - &admin_key age1<from previous step>

creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *admin_key
```

### C. Seed `secrets/secrets.yaml`

```bash
sops secrets/secrets.yaml   # creates and opens for editing
```

Populate at minimum:

- `user_password`, `root_password` — output of `mkpasswd -m SHA-512`
- `ssh_key_github_personal` / `_work` — `ssh-keygen -t ed25519`, paste private key
- `ssh_pubkey_github_personal` / `_work` — the matching `.pub` contents
- `gpg_key_personal` / `_work` — `gpg --export-secret-keys <KEYID>` output
- Any per-environment secrets declared in `system/sops.nix` / `darwin/sops.nix`

### D. Bootstrap each host

For each NixOS host:

1. Install NixOS with a placeholder password and clone this flake.
2. `sudo nixos-rebuild switch --flake .#<host>` — first run generates `/var/lib/sops-nix/key.txt` but fails to decrypt.
3. Follow "Add a new NixOS host" steps 2–5 from above to add the host as a recipient.

For the macOS host: follow "Add a new macOS host" verbatim.

### E. GitHub SSH setup

After the first successful decrypted activation, the SSH keys live
at `~/.ssh/id_rsa_personal` and `~/.ssh/id_rsa_work` (symlinks into
`/run/secrets/`). Test:

```bash
ssh -T github-personal
ssh -T github-work
```

The host aliases are wired up declaratively in
`home/cli/ssh-config.nix`.
