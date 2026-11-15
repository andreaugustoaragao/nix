{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  guest = inputs.self.nixosConfigurations.workstation-k8s-vm;
  image = guest.config.system.build.kubernetesImage;
  state = "/var/lib/workstation-kubernetes";
  runtime = "/run/workstation-kubernetes";
  initialize = pkgs.writeShellScript "initialize-workstation-kubernetes" ''
    set -eu
    umask 077
    cd ${state}
    if [ ! -e root.qcow2 ]; then
      ${pkgs.coreutils}/bin/rm -f root.qcow2.new
      ${pkgs.coreutils}/bin/cp --reflink=auto --sparse=always --no-preserve=mode ${image}/nixos.qcow2 root.qcow2.new
      ${pkgs.qemu_kvm}/bin/qemu-img resize root.qcow2.new 64G
      mv root.qcow2.new root.qcow2
    fi
    if [ ! -e data.raw ]; then
      ${pkgs.coreutils}/bin/truncate -s 0 data.raw.new
      ${pkgs.coreutils}/bin/truncate -s 256G data.raw.new
      ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -q -m 0 -L k3s-data -E root_owner=0:0 data.raw.new
      mv data.raw.new data.raw
    fi
  '';
  shutdown = pkgs.writeScript "shutdown-workstation-kubernetes" ''
    #!${pkgs.python3}/bin/python3
    import json
    import socket
    import time

    deadline = time.monotonic() + 120
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(120)
        connection.connect("${runtime}/qmp.sock")
        with connection.makefile("rwb", buffering=0) as stream:
            def receive():
                connection.settimeout(max(0.1, deadline - time.monotonic()))
                line = stream.readline()
                return json.loads(line) if line else None

            def command(name):
                stream.write((json.dumps({"execute": name, "id": name}) + "\n").encode())
                while True:
                    reply = receive()
                    if reply is None:
                        raise RuntimeError("QEMU disconnected before accepting shutdown")
                    if reply.get("id") == name:
                        if "error" in reply:
                            raise RuntimeError(reply["error"])
                        return

            receive()
            command("qmp_capabilities")
            command("system_powerdown")
            # Do not return while the guest is still flushing its disks.
            while receive() is not None:
                pass
  '';
in
{
  config = {
    users.groups.kubernetes-vm = { };
    users.users.kubernetes-vm = {
      isSystemUser = true;
      group = "kubernetes-vm";
      extraGroups = [ "kvm" ];
    };

    systemd.network = {
      netdevs."20-kubernetes" = {
        netdevConfig = {
          Name = "k3s-tap";
          Kind = "tap";
        };
        tapConfig.User = "kubernetes-vm";
      };
      networks."20-kubernetes" = {
        matchConfig.Name = "k3s-tap";
        address = [ "172.30.75.1/30" ];
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
      internalInterfaces = [ "k3s-tap" ];
      internalIPs = [ "172.30.75.0/30" ];
      forwardPorts =
        map
          (port: {
            proto = "tcp";
            sourcePort = port;
            destination = "172.30.75.2:${toString port}";
            loopbackIPs = [ "192.168.10.75" ];
          })
          [
            80
            443
            6443
          ];
    };
    # The guest can receive replies, but cannot initiate connections to host services.
    networking.firewall.extraCommands = ''
      iptables -I nixos-fw -i k3s-tap -m conntrack --ctstate NEW -j nixos-fw-refuse
    '';

    systemd.services.workstation-kubernetes = {
      description = "Isolated workstation Kubernetes VM";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-networkd.service" ];
      wants = [ "systemd-networkd.service" ];
      # Updating host configuration must not interrupt the running cluster.
      restartIfChanged = false;
      path = [ pkgs.coreutils ];
      preStart = "exec ${initialize}";
      serviceConfig = {
        User = "kubernetes-vm";
        Group = "kubernetes-vm";
        StateDirectory = "workstation-kubernetes";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "workstation-kubernetes";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = state;
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
          "-name workstation-k8s-vm -machine q35,accel=kvm -cpu host"
          "-m 32768 -smp 12 -nodefaults -no-user-config -display none"
          "-serial mon:stdio"
          "-drive file=${state}/root.qcow2,format=qcow2,if=virtio,discard=unmap"
          "-drive file=${state}/data.raw,format=raw,if=virtio,discard=unmap"
          "-netdev tap,id=cluster,ifname=k3s-tap,script=no,downscript=no"
          "-device virtio-net-pci,netdev=cluster,mac=52:54:00:75:00:02"
          "-device virtio-rng-pci"
          "-qmp unix:${runtime}/qmp.sock,server=on,wait=off"
        ];
        ExecStop = shutdown;
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "5min";
        TimeoutStopSec = "150s";
        MemoryMax = "36G";
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

    assertions = [
      {
        assertion = !config.services.k3s.enable;
        message = "Workstation host K3s must be disabled; Kubernetes runs in its KVM guest.";
      }
    ];
  };
}
