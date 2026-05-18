{
  description = "NixOS + nix-darwin configuration for a fleet of machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Tracks nixpkgs-unstable for packages we want fresher than 25.11
    # (niri, zellij, pipewire). See `unstable-pkgs` consumers across
    # system/ and home/.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Pinned to the nixpkgs commit that bumped llama-cpp to b9190, the
    # first build to include MTP speculative decoding (PR ggml-org/llama.cpp#22673,
    # merged 2026-05-16). Drop this input once the nixpkgs-unstable channel
    # branch catches up past b9190 — at that point home/services/local-llm.nix
    # can switch back to using `unstable-pkgs.llama-cpp`.
    nixpkgs-llama.url = "github:NixOS/nixpkgs/dea49413a4cf3be31dc2afb836a90eeee4a5d3c2";
    # Pinned to nixos-25.05 solely to keep xdg-desktop-portal-gnome at
    # version 48.x. GNOME 49 added a hard requirement on
    # org.gnome.Mutter.ServiceChannel that the niri 26.04 in nixpkgs
    # doesn't yet expose, which sends the gnome portal into
    # "Non-compatible display server, exposing settings only" mode and
    # breaks ScreenCast/RemoteDesktop/Screenshot. Drop this input once
    # niri implements ServiceChannel.
    nixpkgs-gnome48.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code = {
      url = "github:sadjow/claude-code-nix";
    };

    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CachyOS-tuned kernels for NixOS. Following our nixpkgs because
    # Lantian's binary cache only holds the build deps (LLVM, patched
    # source) — never the final kernel — so the cache-hash argument
    # for an unfollowed input doesn't apply. Following dedupes the
    # nixpkgs eval and keeps the kernel build aligned with the rest of
    # the system.
    cachyos-kernel = {
      url = "github:xddxdd/nix-cachyos-kernel/release";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nix-darwin,
      sops-nix,
      claude-code,

      ...
    }@inputs:
    let
      metadata = builtins.fromTOML (builtins.readFile ./machines.toml);

      # Get username for the platform
      getUserName = user: _host: user.name;

      # Darwin-platform predicate. macOS hosts live under
      # /Users/<name> and are built with darwinSystem; everywhere else
      # we assume Linux and use nixosSystem.
      isDarwinPlatform =
        platform: platform == "aarch64-darwin" || platform == "x86_64-darwin";

      homePrefixFor = platform: if isDarwinPlatform platform then "/Users" else "/home";

      # Set special args for each machine
      setSpecialArgs = host: {
        isWorkstation = host.profile == "workstation";
        isLaptop = host.profile == "laptop";
        isVm = host.profile == "vm";
        isServer = host.profile == "server";
        isDarwinHost = isDarwinPlatform host.platform;
        homePrefix = homePrefixFor host.platform;
        owner = metadata.user // {
          name = getUserName metadata.user host;
        };
        inherit (host) hostName stateVersion profile;
        # Optional wireless configuration
        wirelessInterface = host.wirelessInterface or null;
        # Optional bluetooth configuration
        bluetooth = host.bluetooth or false;
        # Optional lock screen configuration
        lockScreen = host.lockScreen or false;
        # Optional auto login configuration
        autoLogin = host.autoLogin or false;
        # Enable DankMaterialShell on this host. When true, conflicting
        # daemons (waybar, mako, hyprpaper, swayidle, swayosd,
        # hyprpolkitagent) are not autostarted so DMS owns the screen.
        useDms = host.useDms or false;
        # Optional homebrew casks / brews for Darwin hosts. Ignored on
        # Linux where the darwin/homebrew.nix module isn't imported.
        homebrewCasks = host.homebrewCasks or [ ];
        homebrewBrews = host.homebrewBrews or [ ];
        inherit inputs;
      };

      # Set Home Manager template (works for both NixOS and nix-darwin
      # since both expose `home-manager = { useUserPackages, useGlobalPkgs,
      # ... }` once the corresponding HM module is imported).
      setHomeManagerTemplate = host: {
        home-manager = {
          useUserPackages = true;
          useGlobalPkgs = true;
          extraSpecialArgs = setSpecialArgs host;
          users.${getUserName metadata.user host} = import ./home;
          backupFileExtension = "hm-backup";
        };
      };

      # Partition machines.toml entries by platform.
      machinesBy =
        pred: nixpkgs.lib.filterAttrs (_: host: pred host.platform) metadata.machines;
      linuxMachines = machinesBy (p: !isDarwinPlatform p);
      darwinMachines = machinesBy isDarwinPlatform;
    in
    {
      # NixOS configurations for Linux machines
      nixosConfigurations = builtins.mapAttrs (
        machineName: host:
        nixpkgs.lib.nixosSystem {
          specialArgs = setSpecialArgs host;
          modules = [
            { nixpkgs.hostPlatform = host.platform; }
            {
              nixpkgs.overlays = [
                claude-code.overlays.default
                # See nixpkgs-gnome48 input above for the why.
                (_final: _prev: {
                  inherit (inputs.nixpkgs-gnome48.legacyPackages.${host.platform}) xdg-desktop-portal-gnome;
                })
              ];
            }
            # Hardware configuration
            (./hardware + "/${machineName}" + /hardware-configuration.nix)
            # System configuration
            ./system
            # Prebuilt nix-index database for command-not-found lookup.
            inputs.nix-index-database.nixosModules.nix-index
            # Secrets management
            sops-nix.nixosModules.sops
            # Home Manager configuration
            home-manager.nixosModules.home-manager
            (setHomeManagerTemplate host)
          ];
        }
      ) linuxMachines;

      # nix-darwin configurations for macOS machines. The Darwin module
      # set (./darwin) is intentionally small: no boot/audio/wireless/
      # display-manager, and the home-manager module set under ./home
      # gates its Linux-only pieces on pkgs.stdenv.isLinux.
      darwinConfigurations = builtins.mapAttrs (
        _machineName: host:
        nix-darwin.lib.darwinSystem {
          specialArgs = setSpecialArgs host;
          modules = [
            { nixpkgs.hostPlatform = host.platform; }
            {
              nixpkgs.overlays = [
                claude-code.overlays.default
              ];
            }
            ./darwin
            inputs.nix-index-database.darwinModules.nix-index
            sops-nix.darwinModules.sops
            home-manager.darwinModules.home-manager
            (setHomeManagerTemplate host)
          ];
        }
      ) darwinMachines;
    };
}
