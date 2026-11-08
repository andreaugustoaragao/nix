# Parallels and VMware Fusion development VM comparison

Update November 4: [the completed Fusion 26H1u1 retest](NVME-RETEST.md) still finds NVMe completion timeouts with both default settings and cold-boot queues 8. SATA passed its reliability pilot. Queues 32 and 64 are invalid for this guest.

Run date: November 3, 2026, continuing into November 4 UTC. Five alternating paired rounds per suite on the same Apple M5 Max Mac. Both guests have 8 CPUs and 16 GiB of RAM.

For terminal-heavy development centered on Ghostty and Herdr, I would choose Fusion with the tested SATA disk configuration. Parallels is the stronger choice for bulk and concurrent virtual-disk I/O. I would not move a main development environment onto the Fusion NVMe configuration that timed out here.

Fusion provides the useful graphics advantage for Ghostty and Herdr. Kero uses less CPU once running on Parallels, but its GPU startup repeatedly takes about eight seconds there. The disk comparison has an important condition: Fusion NVMe produced real completion timeouts. The final storage and Go measurements use Fusion's supported SATA controller, with the same VMDK and ext4 filesystem. Parallels retains NVMe.

CPU values below are CPU-seconds consumed during the same approximately eight-second changing text workload. They include the application, its backend, Niri, and other processes belonging to the dedicated test user. The root observer is excluded. Lower values mean less CPU work, not higher measured display FPS. Each cell gives the median and full range of five rounds.

| Application | Parallels CPU-seconds | Fusion CPU-seconds | Rendering path |
|---|---:|---:|---|
| Ghostty | 27.87 [27.56 to 28.42] | 1.46 [1.37 to 1.59] | Parallels llvmpipe; Fusion GPU |
| Herdr | 6.63 [6.34 to 6.85] | 2.45 [2.36 to 2.48] | Parallels software GL; Fusion GPU |
| Kero | 0.45 [0.43 to 0.51] | 2.11 [1.94 to 2.42] | GPU on both |

Excluded thread snapshots attribute most of Parallels' extra Ghostty and Herdr CPU to llvmpipe worker threads. The diagnostic Kero launch records a 7.968-second poll on `anon_inode:sync_file`, independently reproducing its GPU-fence delay. All 90 measured window screenshots are 1280 × 800.

Ghostty uses about 95% less guest CPU on Fusion in this workload. Herdr uses about 63% less. Kero favors Parallels for steady CPU use, although the absolute difference is much smaller than Ghostty's software-rendering cost.

Warm launch means starting a fresh UI with warm filesystem caches and a persistent backend where applicable. Readiness is a terminal child receiving a cursor-position reply. It does not measure first visible pixels or input-to-display latency. The following ranges cover all 15 launches per app on each guest.

| Application | Parallels launch, seconds | Fusion launch, seconds |
|---|---:|---:|
| Ghostty | 0.185 [0.170 to 0.204] | 0.256 [0.242 to 0.314] |
| Herdr | 0.194 [0.178 to 0.272] | 0.188 [0.173 to 0.436] |
| Kero | 8.101 [7.972 to 8.256] | 0.271 [0.250 to 0.465] |

Parallels exposes accelerated OpenGL 4.0 and OpenGL ES 3.0 through VirGL. Fusion exposes OpenGL 4.3 through SVGA3D. Ghostty requires the newer GL path. Herdr rejected the native Parallels adapter, then passed with software GL. Its GPU runs on Fusion disabled Vulkan explicitly, so a Vulkan CPU fallback cannot explain that result. GPU file descriptors and loaded graphics libraries are recorded for every phase.

Kero's repeated Parallels startup delay also appears in the existing [Kero startup investigation](/home/aragao/projects/personal/kero-startup-investigation/REPORT.md). That investigation isolates a first-use GPU-fence wait involving MyGo's complex shader through VirGL. It does not prove the exact internal operation performed by Parallels' proprietary host driver. The new comparison uses the released Kero binary, without reduced shaders.

The final Go series follows the storage tests, after Fusion changed to SATA. Both guests use Go 1.26.10, an empty private build cache for the clean build, and the same `cmd/compile` target. The incremental build changes a source literal. Every resulting compiler must print that literal, report its version, and compile a generic package into a valid object.

| Go build | Parallels, seconds | Fusion SATA, seconds |
|---|---:|---:|
| Clean | 8.904 [8.761 to 9.170] | 9.045 [8.721 to 9.234] |
| Incremental | 0.428 [0.376 to 0.438] | 0.382 [0.377 to 0.431] |

Neither Go build phase establishes a clear speed advantage: the ranges overlap. An excluded CPU profile of the SSA compiler places substantial work in garbage-collector scanning and SSA rewrites. These are compiler CPU measurements, with verified build outputs.

The original NVMe Go series is preserved separately. Its clean-build medians were 8.485 seconds on Parallels and 8.583 seconds on Fusion, with a Fusion range of 8.102 to 20.157 seconds. The slow sample remains in the data. Kernel completion timeouts are an independently observed Fusion storage problem, rather than a basis for silently dropping that sample.

The storage results below use fio 3.41 and guest direct I/O. They include the host cache and each hypervisor's normal storage policies. The VM images reside on the same APFS volume of the Mac's internal SSD. These are virtual-disk completion rates, not raw NAND bandwidth or proof of power-loss durability.

| Storage workload | Unit | Parallels NVMe | Fusion SATA |
|---|---|---:|---:|
| Sequential read | GiB/s | 12.31 [11.76 to 12.62] | 5.65 [5.26 to 7.56] |
| Sequential write | GiB/s | 28.78 [23.81 to 29.85] | 5.03 [4.46 to 7.75] |
| 4 KiB random read, depth 1 | thousand IOPS | 14.4 [14.1 to 22.7] | 11.9 [9.4 to 19.8] |
| 4 KiB random write, depth 1 | thousand IOPS | 15.1 [13.2 to 21.9] | 17.1 [10.3 to 19.2] |
| 4 KiB random read, depth 16 | thousand IOPS | 117.0 [108.0 to 138.1] | 27.8 [23.7 to 76.1] |
| 4 KiB random write, depth 16 | thousand IOPS | 118.0 [109.7 to 126.1] | 42.8 [40.0 to 59.9] |
| 4 KiB write plus fdatasync | thousand writes/s | 13.7 [11.6 to 14.1] | 19.8 [11.7 to 22.0] |
| fdatasync p99 | microseconds | 74.2 [71.2 to 91.6] | 1.7 [1.2 to 2.0] |

Sequential tests transfer 4 GiB through four disjoint 1 GiB streams with 1 MiB requests and aggregate queue depth 16. They reuse a fixed nonzero buffer. An earlier pilot saturated fio's issuing CPU while scrambling buffers; that setup and its partial measurements are excluded. The high cached sequential rates must not be extrapolated to large, uncached, durable writes.

Parallels clearly leads the cached sequential and depth-16 random tests in this configuration. The single-request and sync-write rates vary enough that their ranges overlap.

Random tests use a 2 GiB file, one second of ramp time, and three measured seconds. Single-request results emphasize completion latency; depth-16 results add concurrency. Each final round verifies a separate 64 MiB checksum write/read outside the measured cases. fio byte counts, I/O counts, achieved queue-depth distributions, latency percentiles, CPU statistics, and kernel block counters remain in the raw evidence.

The sync test calls `fdatasync` after every 4 KiB write. Its results depend on the controller's advertised cache policy and the hypervisor's flush behavior. Compare the completion rate as observed by a guest application. Do not interpret a short flush acknowledgement as independently verified physical durability. Parallels advertises write-back caching; Fusion SATA advertises write-through. Cache advertisements are saved in each guest's storage metadata.

Fusion's original NVMe controller logged repeated `timeout, completion polled` warnings. An excluded runtime driver reload with `poll_queues=8` still produced a warning. Switching the existing backing disk to SATA avoids that NVMe path. [Broadcom documents SATA support for Apple-silicon guests](https://knowledge.broadcom.com/external/article/315602/compatibility-considerations-for-arm-guest.html). This test does not establish that another kernel, Fusion release, or NVMe queue configuration cannot fix the original issue.

The final series contains 90 app phases, 70 storage cases, 10 checksum checks, and 20 repeated Go builds. The selected app paths and final storage series completed without reported job errors. New kernel I/O warnings are checked separately in every storage round. Pilot failures and original NVMe warnings are retained. Nonfatal Kero GTK warnings are present in its logs. A short comparison does not establish long-term desktop stability.

Both guests run Niri at 1280 × 800, scale 1, approximately 60 Hz. Apps are Ghostty 1.4.0, Herdr 0.1.12 with core 0.1.17, and Kero 2.1.31, using Mesa 26.1.8. The OS image hash is `2094b28281a8c949f3aca713697f66e6f1977ff43e657c6d97c52756cbfe302d`. The kernel is Linux 6.18.55. The host runs macOS 26.7.1, Parallels 27.0.3, and Fusion 26.0.0.

The current development VM and Kubernetes VM stayed active. Their background load and host power/thermal status are recorded before and after every VM round. One benchmark VM runs at a time, with five seconds to settle after a switch. Close differences remain inconclusive in this shared-host environment.

Each paced test sends 480 changing 80 × 24 text updates at 60 Hz. The generator precomputes the payloads outside timing. A cursor reply confirms terminal processing, but it cannot prove that every update reached the physical display. The bulk test similarly acknowledges parsing 100,000 ANSI lines, not painting every line. Screenshots and excluded diagnostics check visible output separately. Initial PTY sizes sometimes precede the GUI's resize; every grid fits, and final window geometry is checked from screenshots.

For the migration, the existing [Ghostty wrapper](../../home/desktop/ghostty.nix) forces software rendering for every VM. Fusion's GPU benefit requires scoping that fallback to Parallels. The comparison invokes the underlying Ghostty binary with an explicit backend choice. No persistent Nix configuration or development VM was changed. The production NixOS disk layout also differs from these fresh ext4 scratch filesystems.

The [results directory](results/) contains raw measurements, guest evidence archives, summaries, screenshots, provenance, and excluded failure logs. The scripts in this directory reproduce the workloads against the disposable benchmark VMs. Both test VMs are suspended at handoff. The earlier Ghostty Fusion GPU Test VM is preserved separately.
