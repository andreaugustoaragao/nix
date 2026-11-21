# Finish the shared pointer

`prl-dev-vm` and `workstation` share one keyboard and one mouse. The keyboard and mouse stay plugged into the VM. The cursor leaves the VM's left edge and lands on the workstation's portrait monitor, and it comes back the same way.

lan-mouse does the screen edge and the key injection. `cursor-bridge` carries its datagrams. The workstation cannot address `10.211.55.4`, so the VM opens the only connection and both directions ride it.

## What already works

- `pkgs/cursor-bridge` builds. `cargo test` passes three tests. One of them sends a datagram each way and checks that the reply comes back from the address lan-mouse first heard.
- `home/services/cursor-bridge.nix` starts lan-mouse and the bridge with the graphical session on `prl-dev-vm` and `workstation`. The VM dials `192.168.10.75:4243`. The workstation listens there.
- `system/networking.nix` opens UDP `4243` on the workstation.

## What is left

The bridge reads its certificate from `%d/cert` and `%d/key`, and nothing loads those credentials. The service starts, fails to open the certificate, and retries.

`sops` on the workstation cannot decrypt `secrets/secrets.yaml`. This machine holds no age key for it. Do this on `prl-dev-vm`, which does.

1. Generate the keypair and encrypt it.

   ```sh
   tmp=$(mktemp -d)
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
     -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -nodes -subj /CN=cursor-bridge
   openssl pkcs8 -topk8 -nocrypt -in "$tmp/key.pem" -out "$tmp/key.pkcs8.pem"
   sops set secrets/secrets.yaml '["cursor-bridge/cert"]' "$(jq -Rs . < "$tmp/cert.pem")"
   sops set secrets/secrets.yaml '["cursor-bridge/key"]' "$(jq -Rs . < "$tmp/key.pkcs8.pem")"
   rm -rf "$tmp"
   ```

   Confirm the file still decrypts before you commit it:

   ```sh
   sops decrypt --extract '["cursor-bridge/cert"]' secrets/secrets.yaml | head -1
   ```

2. Declare the two secrets in `system/sops.nix`, inside the `lib.optionalAttrs (!isServer)` block, owned by the user:

   ```nix
   "cursor-bridge/cert" = {
     owner = owner.name;
     group = "users";
     mode = "0444";
   };
   "cursor-bridge/key" = {
     owner = owner.name;
     group = "users";
     mode = "0400";
   };
   ```

3. Load them into the bridge in `home/services/cursor-bridge.nix`. The module takes `osConfig`. Add this to the `cursor-bridge` service:

   ```nix
   LoadCredential = [
     "cert:${osConfig.sops.secrets."cursor-bridge/cert".path}"
     "key:${osConfig.sops.secrets."cursor-bridge/key".path}"
   ];
   ```

4. Find the VM's keyboard. `--input /dev/input/event0` is a guess. Read `/proc/bus/input/devices` and pass the event node whose handlers include the keyboard. The service adds the user to the `input` group so it can read that node.

5. Rebuild `prl-dev-vm` and `workstation`. Cross the VM's left edge. The cursor should land on the portrait monitor. Press Scroll Lock on the VM's keyboard. The cursor should come back.

## What not to change

- Do not bind lan-mouse to anything but `127.0.0.1`. Its own packets are not encrypted, and the return path does not exist for them.
- Do not open a port on the VM. The workstation cannot route to `10.211.55.4`.
- Do not add clipboard sharing. It is out of scope.
