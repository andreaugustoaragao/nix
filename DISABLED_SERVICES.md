# Disabled Services for Minimal Hyprland System

This file lists all services and applications that were disabled during the minimal system optimization session.

## System-Level Services (configuration.nix)

### Boot and Visual Services
- **Plymouth boot splash** - `boot.plymouth` - DISABLED
  - Reason: Visual only, saves startup time
  - Re-enable if you want boot splash screen

### Automatic Maintenance Services  
- **Automatic garbage collection** - `nix.gc.automatic` - DISABLED
  - Reason: Can be run manually with `nix-collect-garbage -d`
  - Re-enable for automatic cleanup every week

- **Automatic system updates** - `systemd.timers.auto-upgrade` & `systemd.services.auto-upgrade` - DISABLED
  - Reason: Updates can be run manually
  - Re-enable for automatic system updates every other day

- **Log rotation** - `services.logrotate` - DISABLED
  - Reason: Can manage logs manually
  - Re-enable for automatic log rotation

### Alternative Window Manager
- **Sway compositor** - `programs.sway` - DISABLED
  - Reason: Redundant with Hyprland, only one compositor needed
  - Re-enable if you want Sway as alternative WM

### Container and Network Services
- **Docker** - `virtualisation.docker` - DISABLED
  - Reason: Only enable if you need containers
  - Re-enable if you need Docker containers
  - Also removed user from "docker" group

- **SSH Server** - `services.openssh` - DISABLED
  - Reason: Only enable if you need remote access
  - Re-enable for SSH access to this machine

### Audio System
- **PipeWire audio server** - `services.pipewire` - DISABLED
  - Reason: Using minimal ALSA-only setup
  - Re-enable for advanced audio features, Bluetooth audio, or pro audio
  - Also disabled `security.rtkit`
  - Enabled basic `sound.enable` and explicitly disabled PulseAudio

## User-Level Services (home.nix)

### Window Manager Services
- **Sway window manager** - `wayland.windowManager.sway.enable = false` - DISABLED  
  - Reason: Redundant with Hyprland
  - All Sway startup applications also disabled

### Notification and Status Bar
- **Mako notification daemon** - `services.mako` - DISABLED
  - Reason: Minimal system without notifications  
  - Re-enable if you want desktop notifications

- **Waybar status bar** - `programs.waybar.enable = false` - DISABLED
  - Reason: Minimal system without status bar
  - Re-enable if you want system status bar

### Automatic Services
- **Auto-rebuild monitor** - `systemd.user.services.nixos-auto-rebuild` - DISABLED
  - Reason: Can rebuild manually
  - Re-enable if you want automatic rebuilds on file changes

### Hyprland Autostart Applications
From `exec-once` in Hyprland config:

- **SwayOSD server** - DISABLED
  - Reason: No visual OSD feedback needed for minimal setup
  - Re-enable if you want volume/brightness on-screen display

- **fcitx5 input method** - DISABLED  
  - Reason: Only needed for non-English input
  - Re-enable if you need Chinese/Japanese/Korean input
  - Also removed fcitx5 environment variables

- **Foot terminal server** - DISABLED
  - Reason: Terminals will start individually (slightly slower)
  - Re-enable if you want faster terminal startup

- **Hyprpaper wallpaper daemon** - DISABLED
  - Reason: Using solid color background instead
  - Re-enable if you want wallpaper support

## Summary

**Essential services kept enabled:**
- Hyprland window manager
- Network Manager
- Display manager (greetd)
- Basic ALSA audio

**Total services disabled:** 15+ services and applications

**Result:** Minimal Hyprland system with basic UX functionality maintained.

## Re-enabling Services

To re-enable any service:
1. Uncomment the relevant section in the config files
2. For services with dependencies, also re-enable related services
3. Run system rebuild: `sudo nixos-rebuild switch --flake .`
4. For Home Manager changes: `home-manager switch --flake .`