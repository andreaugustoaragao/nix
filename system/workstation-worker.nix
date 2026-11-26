{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  image = inputs.self.nixosConfigurations.workstation-worker.config.system.build.workerImage;
  state = "/var/lib/workstation-worker";
  runtime = "/run/workstation-worker";
  updateRoot = pkgs.writeShellScript "workstation-worker-update-root" ''
    set -eu
    test "$(id -u)" = 0
    test "$(hostname)" = workstation
    test ! -L ${state}
    test ! -L ${state}/root.qcow2
    test -f ${state}/jobs.raw
    install -d -m 0700 /var/lib/workstation-worker-update
    exec 9>/var/lib/workstation-worker-update/lock
    flock -n 9
    systemctl stop workstation-worker.service
    rm -f /var/lib/workstation-worker-update/root.qcow2.new
    cp --reflink=auto --sparse=always --no-preserve=mode ${image}/nixos.qcow2 /var/lib/workstation-worker-update/root.qcow2.new
    qemu-img resize /var/lib/workstation-worker-update/root.qcow2.new 160G
    chown build-worker-vm:build-worker-vm /var/lib/workstation-worker-update/root.qcow2.new
    chmod 0600 /var/lib/workstation-worker-update/root.qcow2.new
    mv /var/lib/workstation-worker-update/root.qcow2.new ${state}/root.qcow2
    systemctl start workstation-worker.service
  '';
  identities = pkgs.writeShellScriptBin "workstation-worker-identities" ''
    exec /run/wrappers/bin/pkexec --disable-internal-agent ${pkgs.python3}/bin/python3 ${../scripts/workstation-worker-identities.py}
  '';
  update = pkgs.writeShellApplication {
    name = "workstation-worker-update";
    runtimeInputs = [
      pkgs.systemd
      pkgs.polkit
    ];
    derivationArgs = {
      preferLocalBuild = true;
      allowSubstitutes = false;
    };
    text = ''
      echo 'Authenticate to restart the worker VM with the installed Nix image. Persistent home and jobs stay on their separate disk.'
      systemd-run --user --unit=workstation-worker-update --property=Type=exec \
        /run/wrappers/bin/pkexec --disable-internal-agent ${pkgs.writeShellScript "workstation-worker-update" ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.hostname
              pkgs.util-linux
              pkgs.qemu_kvm
              pkgs.systemd
            ]
          }
          exec ${updateRoot}
        ''}
    '';
  };
in
{
  environment.systemPackages = [
    update
    identities
  ];
  users.groups.build-worker-vm = { };
  users.users.build-worker-vm = {
    isSystemUser = true;
    group = "build-worker-vm";
    extraGroups = [ "kvm" ];
  };
  systemd.network = {
    netdevs."21-worker" = {
      netdevConfig = {
        Name = "worker-tap";
        Kind = "tap";
      };
      tapConfig.User = "build-worker-vm";
    };
    networks."21-worker" = {
      matchConfig.Name = "worker-tap";
      address = [ "172.30.76.1/30" ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };
      linkConfig.RequiredForOnline = "no";
    };
  };
  networking.nat = {
    enable = true;
    externalInterface = "enp5s0f0";
    internalInterfaces = [ "worker-tap" ];
    internalIPs = [ "172.30.76.0/30" ];
    forwardPorts = [
      {
        proto = "tcp";
        sourcePort = 2222;
        destination = "172.30.76.2:22";
        loopbackIPs = [ "192.168.10.75" ];
      }
    ];
    extraCommands = ''
      iptables -w -I nixos-filter-forward -i enp5s0f0 -o worker-tap -s 192.168.10.0/24 -d 172.30.76.2 -p tcp --dport 22 -j ACCEPT
    '';
  };
  networking.firewall.extraCommands = ''
    iptables -w -I nixos-fw -i worker-tap -m conntrack --ctstate NEW -j nixos-fw-refuse
  '';
  systemd.services.workstation-worker = {
    description = "Isolated agent and compilation worker VM";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-networkd.service" ];
    wants = [ "systemd-networkd.service" ];
    restartIfChanged = false;
    path = [
      pkgs.coreutils
      pkgs.qemu_kvm
      pkgs.e2fsprogs
    ];
    preStart = ''
      set -eu
      umask 077
      if [ ! -e root.qcow2 ]; then
        rm -f root.qcow2.new
        cp --reflink=auto --sparse=always --no-preserve=mode ${image}/nixos.qcow2 root.qcow2.new
        qemu-img resize root.qcow2.new 160G
        mv root.qcow2.new root.qcow2
      fi
      if [ ! -e jobs.raw ]; then
        truncate -s 0 jobs.raw.new
        truncate -s 512G jobs.raw.new
        mkfs.ext4 -F -q -m 0 -L worker-jobs -E root_owner=0:0 jobs.raw.new
        mv jobs.raw.new jobs.raw
      fi
    '';
    serviceConfig = {
      User = "build-worker-vm";
      Group = "build-worker-vm";
      StateDirectory = "workstation-worker";
      StateDirectoryMode = "0700";
      RuntimeDirectory = "workstation-worker";
      RuntimeDirectoryMode = "0700";
      WorkingDirectory = state;
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
        "-name workstation-worker -machine q35,accel=kvm -cpu host"
        "-m 98304 -smp 20 -nodefaults -no-user-config -display none"
        "-serial mon:stdio"
        "-drive file=${state}/root.qcow2,format=qcow2,if=virtio,discard=unmap"
        "-drive file=${state}/jobs.raw,format=raw,if=virtio,discard=unmap"
        "-netdev tap,id=worker,ifname=worker-tap,script=no,downscript=no"
        "-device virtio-net-pci,netdev=worker,mac=52:54:00:76:00:02"
        "-device virtio-rng-pci"
        "-device virtio-serial-pci"
        "-chardev socket,path=${runtime}/guest-agent.sock,server=on,wait=off,id=guestagent"
        "-device virtserialport,chardev=guestagent,name=org.qemu.guest_agent.0"
        "-qmp unix:${runtime}/qmp.sock,server=on,wait=off"
      ];
      ExecStop = "${pkgs.python3}/bin/python3 ${../scripts/qemu-powerdown.py} ${runtime}/qmp.sock";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "5min";
      TimeoutStopSec = "150s";
      CPUQuota = "2000%";
      CPUWeight = 50;
      IOWeight = 50;
      MemoryMax = "104G";
      UMask = "0077";
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      DevicePolicy = "closed";
      DeviceAllow = [
        "/dev/kvm rw"
        "/dev/net/tun rw"
      ];
    };
  };
  boot.tmp.useTmpfs = lib.mkForce false;
  systemd.slices.user.sliceConfig = {
    CPUWeight = 1000;
    IOWeight = 1000;
    MemoryLow = "16G";
  };
  systemd.services.nix-daemon.serviceConfig = {
    CPUQuota = "1200%";
    MemoryHigh = "16G";
    MemoryMax = "24G";
    CPUWeight = 100;
    IOWeight = 50;
  };
  assertions = [
    {
      assertion = !config.virtualisation.docker.enable;
      message = "The worker host must not expose rootful Docker.";
    }
  ];
}
