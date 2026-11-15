# Workstation Kubernetes isolation

Kubernetes runs in a dedicated NixOS KVM guest. The workstation requires
authentication for host administration and does not run K3s itself.

The user confirmed that the former host cluster contained only disposable
development workloads and explicitly requested deletion. This supersedes the
previous backup and migration plan. Its database, local volumes, images, and
node credentials are discarded. The guest starts a fresh cluster.

## Guest configuration

The systemd-managed QEMU process uses KVM, the host CPU model, 12 virtual CPUs,
and 32 GiB RAM. Its host memory limit is 36 GiB. It starts at boot under the
unprivileged `kubernetes-vm` account. There are no host filesystem shares,
host credentials, Docker sockets, or libvirt access.

The NixOS root disk is 64 GiB. A separate sparse 256 GiB disk holds K3s and the
guest registry. Kubernetes uses embedded etcd, encrypted secrets, and compressed
etcd snapshots with retention of 14 snapshots. Traefik is disabled.

The private TAP network is `172.30.75.0/30`. The host is `.1`, and the guest
is `.2`. Host TCP ports 80, 443, and 6443 forward to the guest. The API certificate
includes `192.168.10.75`, `workstation`, and `workstation.local`. The guest cannot
initiate connections to host services. Host CNI interfaces are no longer trusted.

Ordinary host rebuilds preserve the running VM and existing disks. Guest system
updates require a separate explicit operation. Updating the Nix image alone does
not replace an existing guest root disk.

## One-time retirement

`packages.x86_64-linux.workstation-k3s-retire` provides the task-specific reset
command. It requires GUI-authenticated root execution and the exact checked host
closure through `--system`. The command refuses to run while host K3s units remain
installed. It uses the pinned K3s cleanup helper with the unrelated Tailscale route
reset disabled.

The command removes the old host cluster paths, verifies that Docker and desktop
processes survive, and replaces the unused preparation guest root disk. It keeps
the separate guest data disk and all host Docker data. Root-owned progress records
and a hard link identifying the installed root disk make retries safe across an
interrupted reset. Once the new root is installed, retries never reseed it.

The cluster starts automatically inside the guest without a migration gate.
The old `k3s-default` client context is replaced while external contexts remain.

## Acceptance

The installed host must have no K3s service, lazy-start unit, database, local
volumes, mounts, or CNI interfaces. The guest must have a Ready node named
`workstation-k8s-vm` with only fresh default workloads. The API must work through
the workstation endpoint. Docker containers, desktop processes, authenticated
sudo, and the separate rootless Docker daemon must remain available.

This task needs only a workstation activation. It must not restart the development
VM's Shared Vault process or its graphical session.

Runtime acceptance passed on 2026-11-15 UTC. The [verification record](evidence/workstation-k3s-retirement-20261114.json) captures the active host and guest closures, fresh node identity, clean host networking, API access, and a second authenticated run that preserved the running guest. The external `ec-avaya-mdb15` context remains selected. Use `kubectl --context workstation-k8s-vm` for the new development cluster.
