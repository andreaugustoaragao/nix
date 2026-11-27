# `maui` — Self-Sufficient Operations & Bare-Metal Recovery

`maui` (`192.168.40.3`) is the LAN home server running Vaultwarden, Continuwuity Matrix, Grafana + Prometheus, Nginx + ACME TLS, and Samba Time Machine backups. All configuration and secrets live declaratively in this flake (`machines.toml`, `hardware/maui/`, `system/maui/`, `secrets/maui.yaml`), with `users.mutableUsers = false`.

`maui` has no build dependency on `workstation` (its profile uses `nixpkgs-unstable` and `system/maui/` directly, without importing private `fulcrum-src` inputs or workstation Home Manager modules).

---

## Day-to-Day Updates Directly on `maui`

Clone this repository once to `/home/adm/nix`:

```bash
git clone https://github.com/andreaugustoaragao/nix.git /home/adm/nix
```

Apply configuration changes and verify every core service locally:

```bash
cd /home/adm/nix
git pull
sudo nixos-rebuild switch --flake .#maui
maui-verify
```

For privileged secret verification (checks all 10 decrypted files under `/run/secrets/`):

```bash
sudo maui-verify
```

---

## Bare-Metal Recreation (Without `workstation`)

1. **Boot NixOS minimal ISO and prepare filesystems:**
   - Partition the OS disk with `NIXROOT` (`ext4`), `NIXBOOT` (`vfat`), and `SWAP` labels matching `hardware/maui/hardware-configuration.nix` (or update labels/UUIDs for new hardware).
   - Attach the existing `/data` Btrfs pool (`UUID 6f5263c5-e353-4734-8fef-8601c1f8978c`) or update `/data`'s UUID in `hardware/maui/hardware-configuration.nix`.
   - Mount `/mnt`, `/mnt/boot`, and enable swap (`swapon`).

2. **Provision the `sops-nix` host age key:**
   - Preferred (zero dependency on `workstation`): restore your backed-up `/var/lib/sops-nix/key.txt` from Vaultwarden/offline backup onto the target root:
     ```bash
     install -d -m 0755 /mnt/var/lib/sops-nix
     install -m 0600 /path/to/maui-sops-key.txt /mnt/var/lib/sops-nix/key.txt
     ```
   - Alternate (new hardware key): generate a fresh key with `age-keygen -o /mnt/var/lib/sops-nix/key.txt` (`chmod 0600`), update `&maui_key` in `.sops.yaml` and `keys/maui.age.pub`, run `sops updatekeys secrets/maui.yaml` from a machine holding `*admin_key`, and commit/push.

3. **Install NixOS declaratively:**
   ```bash
   nixos-install --no-root-passwd --flake github:andreaugustoaragao/nix/main#maui
   ```
   All user passwords (`adm`, `root`) and service secrets (`grafana_secret_key`, `vaultwarden_env`, `acme_cloudflare_env`, `matrix_bot_token`, `matrix_alert_room_id`, `healthchecks_upgrade_url`, `nginx_origin_cert`, `nginx_origin_key`) decrypt automatically from `secrets/maui.yaml` at boot.

4. **Restore stateful application data & verify:**
   - Ensure `/data` (`vaultwarden` backups, `matrix` RocksDB data under `/data/services/matrix`, Time Machine data under `/data/timemachine`) and `/var/lib/{bitwarden_rs,grafana,prometheus2,acme,samba/private}` are in place.
   - If bootstrapping Samba from an empty `/var/lib/samba/private` instead of restoring `passdb.tdb`, set the Samba password for Time Machine once:
     ```bash
     sudo smbpasswd -a backup
     ```
   - Reboot into the installed system and run `sudo maui-verify`.

5. **Greenfield Matrix bot setup (only if provisioning new Matrix bots):**
   - Use `scripts/maui/setup-matrix-bot.sh` (upgrade alerts) and `scripts/maui/setup-fulcrum-bot.sh` (Fulcrum bot), then encrypt the generated tokens/room IDs into `secrets/maui.yaml` via `sops secrets/maui.yaml` and remove the temporary plaintext files from `/data/services/matrix/`.
