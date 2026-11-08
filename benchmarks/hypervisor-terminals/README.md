# Compare terminal applications in disposable VMs

1. Provision two dedicated NixOS guests with the same image, application versions, Go toolchain, CPU count, memory, display mode, and empty 32 GiB disk. The recorded experiment uses Niri at 1280 × 800 and 8 CPUs with 16 GiB of memory.
2. Install `guest.py` and `terminal_workload.py` in `/opt/vmperf` on each guest. Supply the absolute application paths in `/etc/benchmark-packages.json`. Use the recorded metadata to match those paths and versions.
3. Run `python3 /opt/vmperf/guest.py prepare` as root in each disposable guest. This command formats the single empty 32 GiB disk and mounts it at `/bench`. It refuses disks with an existing filesystem other than ext4.
4. Run an excluded pilot for every app on both guests. For example, use `python3 /opt/vmperf/guest.py app --app ghostty --trial -1 --pilot`. Use a new trial number for every retry.
5. Confirm the screenshots and graphics evidence. For Herdr on Parallels, set `/bench/render-modes.json` to `{"herdr":"software-gl"}` after confirming that the native adapter fails. Ghostty selects llvmpipe when the guest lacks OpenGL 4.3.
6. Start both named benchmark VMs. Configure root SSH aliases `vmperf-parallels` and `vmperf-fusion`, plus an SSH wrapper for the Mac host. The controller uses the disposable VM names and Fusion path declared in `compare.py`.
7. Run the controller with an unused positive trial range:

```sh
python3 compare.py \
  --ssh-config /path/to/ssh_config \
  --mac-ssh /path/to/mac-ssh \
  --output /path/to/results \
  --first-trial 10 --rounds 5
```

8. Validate the completed work and summarize the measurements:

```sh
python3 analyze.py /path/to/results > summary.json
```

The controller suspends one benchmark VM before it resumes the other. Both end suspended. It preserves other VMs. A stopped run can reuse complete VM rounds with `--resume-results`; incomplete app trials need a new trial number because the guest refuses to overwrite evidence.

For an excluded Go CPU profile, run `python3 /opt/vmperf/guest.py profile-go --trial -20`. Inspect `/bench/runs/go--20/profile-top.txt`. Do not compare the instrumented build time with regular build times.

The report and evidence for the November 2026 run accompany these scripts. Their measurements describe short controlled workloads. They do not establish long-term desktop reliability or on-screen frame rate.

For the storage suite, install the same fio binary as `/opt/vmperf/fio` on both guests and copy `storage.py` alongside it. Run `python3 /opt/vmperf/storage.py prepare` to write the dedicated test files. Then run an excluded pilot with `python3 /opt/vmperf/storage.py run --trial -1`.

Start both benchmark VMs and run `compare.py` with `--suite storage`, a separate output directory, and an unused trial range. Summarize that directory with `python3 analyze.py --storage /path/to/storage-results`.

Storage tests use guest direct I/O. They retain host caching and the hypervisors' normal storage policies. The sequential tests transfer 4 GiB through four disjoint 1 GiB streams at aggregate queue depth 16. They reuse a fixed nonzero buffer to avoid CPU limits from per-write data generation. Random tests use 4 KiB operations at depths 1 and 16. The sync test calls `fdatasync` after every 4 KiB write. Each round also verifies a separate 64 MiB checksum file outside the measured cases.

The recorded storage comparison uses Parallels NVMe and Fusion SATA. Fusion NVMe produced completion timeouts, including after an excluded `poll_queues=8` driver test. SATA preserves the same VMDK and ext4 filesystem. These controller differences are part of the usable configurations being compared. Add `--include-go` to repeat the Go builds after each storage round. The storage summary includes those builds when present.
