{
  config,
  pkgs,
  lib,
  hostName,
  bluetooth ? false,
  ...
}:

let
  # BlueZ 5.86 never resets hog->report_map_id after a failed or cancelled
  # Report Map read, permanently blocking uHID creation on reconnects until
  # bluetoothd restarts.
  bluezPatched = pkgs.bluez.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ../pkgs/patches/bluez-hog-reset-report-map-id.patch
    ];
  });
in
{
  config = lib.mkIf bluetooth {
    hardware = {
      # Enable Bluetooth hardware
      bluetooth = {
        enable = true;
        powerOnBoot = true;
        package = bluezPatched;
      };
      # MT7925 combo chip: firmware is already provided by linux-firmware
      # (via hardware.enableRedistributableFirmware in hardware-configuration.nix).
      # broadcom-bt-firmware is kept here for other hosts (hp-laptop) that may
      # use Broadcom adapters; it's a no-op on the workstation.
      firmware = [ pkgs.broadcom-bt-firmware ];
    };

    services = {
      # Enable Bluetooth service
      blueman.enable = true;

      # Enable PulseAudio/PipeWire Bluetooth support
      pulseaudio.package = lib.mkIf config.services.pulseaudio.enable (
        pkgs.pulseaudio.override { bluetoothSupport = true; }
      );

      # For PipeWire (which is more common in modern setups)
      pipewire.wireplumber.extraConfig = lib.mkIf config.services.pipewire.enable {
        "10-bluez" = {
          "monitor.bluez.properties" = {
            "bluez5.enable-sbc-xq" = true;
            "bluez5.enable-msbc" = true;
            "bluez5.enable-hw-volume" = true;
            "bluez5.roles" = [
              "a2dp_sink"
              "a2dp_source"
              "hsp_hs"
              "hsp_ag"
              "hfp_hf"
              "hfp_ag"
            ];
          };
        };
      };
    };

    # MT7925 combo chip boot race workaround (workstation only).
    #
    # The MT7925 exposes WiFi (PCIe, mt7925e) and BT (USB, btusb/btmtk) as
    # separate interfaces on the same physical chip. On cachyos kernels btusb
    # probes and attempts the WMT firmware handshake before mt7925e has
    # finished initialising the shared PCIe bus — the WMT command times out
    # after 10 s, leaving hci0 dead (BD address 00:00:00:00:00:00, state DOWN).
    #
    # Recovery has two levels: btusb driver unbind/rebind (cheap) and USB-level
    # deauthorize/reauthorize of the whole 0e8d:0717 device (deeper — re-runs
    # USB enumeration so the firmware download starts from a clean device
    # state). One driver rebind sometimes isn't enough (the post-rebind WMT
    # probe can hit the same timeout), so we verify after every attempt and
    # escalate to the USB-level reset up to MAX_ATTEMPTS times.
    systemd.services.bt-mt7925-rebind = lib.mkIf (hostName == "workstation") {
      description = "Recover MT7925 BT after PCIe init race (verify + retry)";
      after = [ "bluetooth.service" ];
      wants = [ "bluetooth.service" ];
      wantedBy = [ "bluetooth.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        TimeoutStartSec = 180;
        ExecStart = pkgs.writeShellScript "bt-mt7925-rebind" ''
          set -u
          LOG() { echo "bt-mt7925-rebind: $*" >&2; }

          hci_addr() {
            ${bluezPatched}/bin/btmgmt info 2>/dev/null | \
              ${pkgs.gawk}/bin/awk '
                /^hci0:[[:space:]]+Primary controller/ { in_hci0 = 1; next }
                /^hci[0-9]+:/ { in_hci0 = 0 }
                in_hci0 && $1 == "addr" { print $2; exit }
              ' || true
          }
          is_healthy() {
            local a
            a=$(hci_addr)
            [ -n "$a" ] && [ "$a" != "00:00:00:00:00:00" ]
          }

          # Wait up to 18 s for the WMT firmware handshake to complete (timeout
          # itself is 10 s; allow margin for slow probes and rfkill settling).
          wait_for_hci() {
            local i
            for i in $(seq 1 18); do
              sleep 1
              if is_healthy; then return 0; fi
            done
            return 1
          }

          if is_healthy; then
            LOG "hci0 healthy ($(hci_addr)) at startup, nothing to do"
            exit 0
          fi

          # Give mt7925e time to finish PCIe firmware load before deciding.
          sleep 5

          if is_healthy; then
            LOG "hci0 healthy ($(hci_addr)) after startup settle, nothing to do"
            exit 0
          fi

          # Locate the parent USB device for the MT7925 BT (0e8d:0717). Bus
          # numbering can shift between boots, so don't hard-code 3-7.
          USB_DEV=""
          for dev in /sys/bus/usb/devices/*; do
            [ -e "$dev/idVendor" ] || continue
            [ -e "$dev/idProduct" ] || continue
            if [ "$(cat "$dev/idVendor")" = "0e8d" ] && \
               [ "$(cat "$dev/idProduct")" = "0717" ]; then
              USB_DEV=$(basename "$dev")
              break
            fi
          done
          if [ -z "$USB_DEV" ]; then
            LOG "MT7925 BT (0e8d:0717) not found on USB bus, cannot recover"
            exit 1
          fi
          LOG "MT7925 BT at usb device $USB_DEV"

          BT_USB_DRV="/sys/bus/usb/drivers/btusb"

          driver_rebind() {
            local ifaces iface
            ifaces=$(ls "$BT_USB_DRV" 2>/dev/null | \
                     grep -E '^[0-9]+-[0-9.]+:[0-9]+\.[0-9]+$' || true)
            if [ -z "$ifaces" ]; then
              LOG "driver_rebind: no btusb interfaces bound"
              return 1
            fi
            for iface in $ifaces; do
              LOG "driver_rebind: unbinding $iface"
              echo "$iface" > "$BT_USB_DRV/unbind" 2>/dev/null || true
            done
            sleep 1
            for iface in $ifaces; do
              LOG "driver_rebind: rebinding $iface"
              echo "$iface" > "$BT_USB_DRV/bind" 2>/dev/null || true
            done
          }

          usb_reauthorize() {
            local f="/sys/bus/usb/devices/$USB_DEV/authorized"
            if [ ! -w "$f" ]; then
              LOG "usb_reauthorize: $f not writable"
              return 1
            fi
            LOG "usb_reauthorize: deauthorizing $USB_DEV"
            echo 0 > "$f" 2>/dev/null || true
            sleep 2
            LOG "usb_reauthorize: reauthorizing $USB_DEV"
            echo 1 > "$f" 2>/dev/null || true
          }

          MAX_ATTEMPTS=4
          for attempt in $(seq 1 $MAX_ATTEMPTS); do
            LOG "attempt $attempt/$MAX_ATTEMPTS: hci0 wedged (addr='$(hci_addr)')"
            if [ "$attempt" -eq 1 ]; then
              driver_rebind || true
            else
              usb_reauthorize || true
            fi
            ${pkgs.util-linux}/bin/rfkill unblock bluetooth 2>/dev/null || true
            if wait_for_hci; then
              LOG "attempt $attempt: hci0 recovered ($(hci_addr))"
              exit 0
            fi
            LOG "attempt $attempt: still wedged after recovery"
          done

          LOG "all $MAX_ATTEMPTS attempts failed, hci0 still wedged"
          exit 1
        '';
      };
    };

    # Add Bluetooth packages for GUI management
    environment.systemPackages = with pkgs; [
      bluez-tools
      blueman
    ];
  };
}
