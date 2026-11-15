# Workstation privilege hardening and Kubernetes migration

The workstation must require authentication for host administration. Kubernetes
must run in a dedicated KVM guest with its own disk, credentials, and kernel.
Existing cluster data and local images survive the move.

## Acceptance gates

1. The active workstation denies uncached passwordless sudo and access to the
   rootful Docker socket. Unattended Nix activation is disabled. Rootless Docker
   works. Existing desktop and container workloads remain available.
2. The Kubernetes guest boots as a dedicated unprivileged host account. It has
   no host filesystem shares, host credentials, Docker socket, or libvirt access.
3. A protected cold backup preserves cluster identity, database, all local-path
   volumes, and every image needed by workloads. A rollback copy remains intact.
4. Only one copy of the restored cluster runs. The guest uses the original node
   name so local-volume affinity remains valid. API and ingress clients continue
   to work through deliberately configured endpoints.
5. After cutover, the workstation's host K3s and lazy-start units are disabled.
   Reboot does not start host K3s. Guest workload and volume identity are checked
   against the saved inventory, including pre-existing failures.

## Delivery sequence

- [x] Inspect effective workstation privilege policy and existing workloads.
- [x] Build a hardening candidate without changing active privileges.
- [x] Refresh the candidate against the latest independent login/session edits.
- [x] Apply hardening with desktop authentication and check effective access.
- [ ] Deploy shared Herdr customizations, agent settings, and all portable skills.
- [ ] Build and boot an isolated guest with Kubernetes gated off.
- [ ] Measure and back up the cluster's actual data and local image content.
- [ ] Stop host Kubernetes for a consistent final copy and controlled cutover.
- [ ] Verify the restored guest, then disable host Kubernetes declaratively.
- [ ] Verify reboot behavior and publish only task-owned source changes.

## Architecture decision

Use a NixOS-built disk image and a systemd-managed QEMU/KVM process. A dedicated
host account owns only the guest disk and runtime files. This avoids granting
desktop or agent accounts root-equivalent libvirt control. It also avoids the
host store and exchange-directory shares enabled by the development VM module.

A private TAP link gives the host and guest stable addresses. NAT supplies guest
egress. Forward only selected API and ingress ports at cutover. Do not change the
physical workstation interface or restart its graphical session.

Reuse the dedicated Kubernetes profile, with explicit network parameters. The
existing Parallels guest keeps its current defaults. The workstation guest must
initially keep its K3s service stopped until the migration explicitly enables it.
Preserve the source cluster's datastore format and node identity during migration.
Do not combine datastore conversion with moving workloads into a VM.

Keep hardening and cluster cutover as separate verifiable units. The workstation
has a paused independent session with seven login files. The user authorized
merging those files together with this work. Preserve those working files and
index states, and never activate an older snapshot over a newer login fix.

## Throughput checkpoint

Build and verify host policy before copying data. Boot the empty guest before
scheduling cluster downtime. Measure actual data and image sizes before selecting
the final copy method. Stop if the target would replace newer unrelated source or
if the backup cannot be restored without destroying the original state.
