{
  config,
  lib,
  pkgs,
  owner,
  hostName,
  stateVersion,
  ...
}:
let
  keys =
    role:
    map (host: lib.fileContents (../../secrets/workers/clients + "/${role}-${host}.pub")) [
      "prl-dev-vm"
      "workstation"
    ];
  identity = "/home/.worker-identity";
  clientSigningKeys = map (host: ../../secrets/workers/clients + "/cache-${host}.pub") [
    "prl-dev-vm"
    "workstation"
  ];
  # Minimal self-contained flake for `/etc/workstation-worker/source#rust-worker`
  # so unrelated edits to the repository do not invalidate the 25 GiB worker image.
  rootLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  nixpkgsNode = rootLock.nodes.root.inputs.nixpkgs;
  rustOverlayNode = rootLock.nodes.root.inputs.rust-overlay;
  nixpkgsOrig = rootLock.nodes.${nixpkgsNode}.original;
  nixpkgsRef = nixpkgsOrig.rev or nixpkgsOrig.ref;
  workerFlakeNix = ''
    {
      description = "Pinned Rust worker development shell";
      inputs = {
        nixpkgs.url = "github:${nixpkgsOrig.owner}/${nixpkgsOrig.repo}/${nixpkgsRef}";
        rust-overlay = {
          url = "github:oxalica/rust-overlay";
          inputs.nixpkgs.follows = "nixpkgs";
        };
      };
      outputs =
        { nixpkgs, rust-overlay, ... }:
        let
          systems = [
            "x86_64-linux"
            "aarch64-linux"
          ];
        in
        {
          devShells = nixpkgs.lib.genAttrs systems (
            system:
            let
              pkgs = import nixpkgs {
                inherit system;
                overlays = [ rust-overlay.overlays.default ];
              };
            in
            {
              rust-worker = pkgs.callPackage ./pkgs/rust-worker-shell.nix { };
            }
          );
        };
    }
  '';
  workerFlakeLock = builtins.toJSON {
    nodes = {
      root.inputs = {
        nixpkgs = nixpkgsNode;
        rust-overlay = rustOverlayNode;
      };
      ${nixpkgsNode} = rootLock.nodes.${nixpkgsNode};
      ${rustOverlayNode} = rootLock.nodes.${rustOverlayNode};
    };
    root = "root";
    inherit (rootLock) version;
  };
  workerSource = pkgs.runCommandLocal "workstation-worker-source" { } ''
    mkdir -p "$out/pkgs"
    cp ${pkgs.writeText "flake.nix" workerFlakeNix} "$out/flake.nix"
    cp ${pkgs.writeText "flake.lock" workerFlakeLock} "$out/flake.lock"
    cp ${pkgs.writeText "rust-toolchain.toml" (builtins.readFile ../../rust-toolchain.toml)} "$out/rust-toolchain.toml"
    cp ${pkgs.writeText "rust-toolchain.nix" (builtins.readFile ../../pkgs/rust-toolchain.nix)} "$out/pkgs/rust-toolchain.nix"
    cp ${pkgs.writeText "rust-worker-shell.nix" (builtins.readFile ../../pkgs/rust-worker-shell.nix)} "$out/pkgs/rust-worker-shell.nix"
  '';
in
{
  imports = [ ./identity.nix ];
  nixpkgs.config.allowUnfree = true;
  networking = {
    inherit hostName;
    useNetworkd = true;
    useDHCP = false;
    firewall = {
      enable = true;
      allowedTCPPorts = [ ];
      extraCommands = ''
        iptables -A nixos-fw -s 172.30.76.1/32 -p tcp --dport 22 -j nixos-fw-accept
        iptables -A nixos-fw -s 192.168.10.0/24 -p tcp --dport 22 -j nixos-fw-accept
      '';
    };
  };
  systemd.network = {
    enable = true;
    networks."10-ethernet" = {
      matchConfig.Name = "en*";
      networkConfig = {
        Address = "172.30.76.2/30";
        Gateway = "172.30.76.1";
        DNS = [
          "192.168.100.2"
          "9.9.9.9"
        ];
        IPv6AcceptRA = false;
      };
    };
  };
  services.resolved.enable = true;
  services.timesyncd.enable = true;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      sandbox = true;
      trusted-users = [ "root" ];
      allowed-users = [
        "root"
        "nix-ssh"
        owner.name
      ];
      cores = 10;
      max-jobs = 2;
      auto-optimise-store = true;
      min-free = 30 * 1024 * 1024 * 1024;
      max-free = 60 * 1024 * 1024 * 1024;
      secret-key-files = [ "${identity}/cache.sec" ];
      trusted-public-keys = map lib.fileContents (builtins.filter builtins.pathExists clientSigningKeys);
    };
    sshServe = {
      enable = true;
      write = true;
      trusted = false;
      protocol = "ssh-ng";
      keys = keys "nix";
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };
  systemd.tmpfiles.rules = [ "d ${identity} 0700 root root -" ];
  systemd.services.nix-daemon = {
    requires = [ "worker-identity.service" ];
    serviceConfig = {
      MemoryHigh = "32G";
      MemoryMax = "48G";
      CPUQuota = "1600%";
    };
  };
  systemd.user.slices.build-jobs.sliceConfig = {
    MemoryHigh = "32G";
    MemoryMax = "40G";
    CPUQuota = "1600%";
  };
  services.dbus.enable = true;
  hardware.graphics.enable = true;
  fonts.packages = [
    pkgs.noto-fonts
    pkgs.noto-fonts-color-emoji
    pkgs.dejavu_fonts
    pkgs.nerd-fonts.caskaydia-mono
  ];
  services.openssh = {
    enable = true;
    openFirewall = false;
    hostKeys = [
      {
        path = "${identity}/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    extraConfig = ''
      Match User ${owner.name}
        AllowTcpForwarding local
        PermitOpen 127.0.0.1:*
      Match all
    '';
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [
        owner.name
        "nix-ssh"
      ];
      AllowAgentForwarding = false;
      AllowTcpForwarding = "no";
      AllowStreamLocalForwarding = "no";
      X11Forwarding = false;
      PermitTunnel = false;
    };
  };
  systemd.services.sshd-keygen = {
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = [ "/home" ];
  };
  users.users.${owner.name} = {
    uid = 1000;
    isNormalUser = true;
    linger = true;
    extraGroups = [ ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = keys "agent";
  };
  security.sudo.enable = false;
  virtualisation.docker = {
    enable = false;
    rootless = {
      enable = true;
      package = pkgs.docker_29;
      setSocketVariable = true;
    };
  };
  programs = {
    fish.enable = true;
    dconf.enable = true;
    bash.enable = true;
    zsh.enable = true;
    nix-ld.enable = true;
  };
  environment.systemPackages = [
    (pkgs.callPackage ../../pkgs/workstation-jobs.nix { }).worker
    pkgs.git
    pkgs.rsync
    pkgs.python3
    pkgs.jq
    pkgs.sccache
    pkgs.curl
  ];
  environment.etc."workstation-worker/source".source = workerSource;
  security.pki.certificateFiles = [
    ../../certs/internal-root-2.pem
    ../../certs/internal-root-1.pem
    ../../certs/internal-intermediate.pem
    ../../certs/proxy-root.pem
    ../../certs/netskope-root.pem
  ];
  time.timeZone = "America/Denver";
  assertions = [
    {
      assertion =
        lib.unique config.nix.settings.trusted-users == [ "root" ] && !config.nix.sshServe.trusted;
      message = "Worker SSH accounts must remain untrusted Nix clients.";
    }
    {
      assertion =
        !config.security.sudo.enable
        && !config.security.doas.enable
        && !config.virtualisation.docker.enable
        &&
          lib.intersectLists [
            "wheel"
            "docker"
            "kvm"
            "libvirtd"
          ] config.users.users.${owner.name}.extraGroups == [ ];
      message = "Worker jobs must not gain administrative, rootful Docker or host-device privileges.";
    }
    {
      assertion = lib.all (
        name:
        builtins.elem name (
          builtins.fromJSON (builtins.readFile ../../secrets/workers/credential-names.json)
        )
      ) (builtins.attrNames config.sops.secrets);
      message = "The worker may decrypt only its selected agent and Git development credentials.";
    }
  ];
  system.stateVersion = stateVersion;
  systemd.coredump.enable = false;
}
