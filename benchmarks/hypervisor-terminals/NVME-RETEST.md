# VMware NVMe workaround retest, November 4, 2026

Fusion 26H1u1, app version 26.0.1 and build 25689522, still reproduces the NVMe completion timeouts in this NixOS guest. Cold-boot polling queues of eight do not fix it. SATA passed the same engine's reliability pilot.

| Fusion 26H1u1 configuration | Kernel completion timeouts | Outcome |
|---|---:|---|
| Default NVMe, polling queues 0 | 7 | failed reliability gate |
| NVMe, cold-boot polling queues 8 | 2 | failed reliability gate |
| SATA control | 0 | passed reliability pilot |

The default-NVMe test completed the seven-case fio suite, a clean and incremental Go compiler build, 60 seconds of mixed random I/O at depth 64, and a separate 64 MiB CRC write/read. The kernel recorded seven completion timeouts. Individual sequential-write and queued-random-read cases took approximately 31 and 33 seconds. The compiler build took 20.759 seconds clean. These are diagnostic pilot observations, not speed-comparison medians. Checksum verification passed, so the observation is repeated stalls without observed checksum corruption.

The polling-queues-eight test produced two kernel completion timeouts during the storage suite. It failed the reliability gate, so further compiler and stress tests were skipped. Ordinary libaio and Go filesystem operations were used, rather than changing the workload to polling-only I/O.

The SATA control passed all seven storage cases, the compiler correctness checks, 60 seconds of mixed random I/O, and the 64 MiB checksum verification without kernel I/O warnings. Its one-run clean and incremental compiler times were 17.334 and 0.694 seconds. Passing this pilot does not establish long-term stability. The [original five-pair performance comparison](REPORT.md) remains the source of throughput medians and ranges; its measured Fusion version was 26.0.0.

The newer engine was verified from both its executing process path and the logs of all three VMs, which identify build 25689522. The test used the initialized, signature-verified app in `/Users/aragao/Downloads/vmware-nvme-retest-20261104/VMware Fusion.app`. The older `/Applications/VMware Fusion.app` bundle was not replaced. Local administrator initialization resolved the earlier setup blocker.

The online values `nvme.poll_queues=32` and `64` do not work in this eight-CPU guest. Both earlier cold boots rejected the parameter and prevented the NVMe module from loading. The original recommendation missed that limit. The unchanged pinned Linux 6.18.55 driver validates the count against `blk_mq_num_possible_queues(0)`. This guest has eight possible CPUs (`0-7`). The check is in `io_queue_count_set` in [the matching kernel source](https://raw.githubusercontent.com/gregkh/linux/v6.18.55/drivers/nvme/host/pci.c). Those invalid settings were not rerun on the newer hypervisor because the guest kernel and CPU topology are unchanged.

On the older Fusion 26.0.0, cold-boot queues eight also loaded successfully but produced six completion timeouts during the reliability pilot. Both valid queues-eight configurations reported seven normal and eight polling queues. No timed speed ranking was produced for a configuration that failed the reliability gate.

The disk and ext4 filesystem were cloned consistently from the owned, frozen scratch disk. Both NVMe variants and SATA retain eight CPUs and 16 GiB of memory, the same Linux image, Mesa 26.1.8, fio 3.41, and Go 1.26.10. Each test preconditions its private files. The boot images retain the same kernel, initrd, and squashfs. Only the GRUB timeout and kernel parameter changed for the polling variants.

The [evidence directory](results/nvme-retest-20261104/) contains original boot rejections and old-engine results. The [new-engine results](results/nvme-retest-20261104/fusion26h1u1/) contain complete fio output, I/O byte counts, Go-output checks, CRC results, command lines, module parameters, queue counts, interrupt counters, kernel logs, and engine-build identification. Host load, AC power, and thermal-warning status are also recorded. Guest direct I/O still includes host caching; this retest does not establish raw SSD bandwidth or power-loss durability.

The update DMG was downloaded from an archive.org mirror. Its SHA-256 is `df1911f8de651818a43c20ca1054403da7e39534f15a2e0e0f9d41ffcf728ab8`. Full Apple code-signature validation passed with VMware's Team ID `EG7KH642X6`, matching the installed app, and Gatekeeper accepted it as notarized.

This retest does not support moving the main development environment onto the tested Fusion NVMe configuration. The update and valid polling-queue workaround both failed. SATA remains the working configuration in these tests. This does not rule out fixes in another Linux kernel or a different Fusion device configuration.

The new default-NVMe and queues-eight VMs are powered off. The SATA control is suspended. The original benchmark and GPU-test VMs remain preserved, the Parallels development and Kubernetes VMs remain running, and no persistent Nix configuration was changed.
