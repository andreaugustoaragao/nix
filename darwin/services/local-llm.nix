{
  config,
  pkgs,
  lib,
  inputs,
  owner,
  homePrefix,
  ...
}:

let
  # Mirror the workstation pin (nixpkgs-llama is the rev with llama.cpp
  # b9190 — first build with MTP speculative decoding). Same input is
  # used in home/services/local-llm.nix so both hosts ship the same
  # binary semantics; only the GPU backend differs.
  llama-pkgs = import inputs.nixpkgs-llama {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # No override here: nixpkgs builds llama.cpp with Metal acceleration
  # by default on Darwin. The workstation derivation passes
  # `rocmSupport = true` because its AMD GPU needs explicit ROCm
  # wiring; Apple Silicon needs no equivalent toggle.
  llama-cpp-metal = llama-pkgs.llama-cpp;

  # M5 Max + 128 GB unified memory has none of the 16 GB-VRAM
  # constraints that forced Q4 on workstation. Bump to Q8_K_XL of
  # the same MoE — ~38 GB resident, near-FP16 quality at half the
  # size, KV cache @196k still fits comfortably. The alias is
  # deliberately distinct from workstation's `qwen3.6-35b-a3b-local`
  # so pi conversation history makes it clear which quant served
  # any given turn (workstation = Q4, mac-work = Q8).
  model = {
    id = "qwen3.6-35b-a3b-q8-local";
    name = "Qwen3.6 35B A3B Local (Q8)";
    repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
    file = "Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf";
    contextWindow = 196608;
    maxTokens = 8192;
  };

  homeDir = "${homePrefix}/${owner.name}";
  modelDir = "${homeDir}/.local/share/llm/models";
  modelPath = "${modelDir}/${model.file}";
  modelUrl = "https://huggingface.co/${model.repo}/resolve/main/${model.file}?download=true";

  # Parallels Shared-network host stub — the Mac's own IP on the
  # bridge100 interface (verified via `ifconfig` on mac-work). NOT
  # 10.211.55.1: that's the virtual router endpoint prl-dev-vm uses
  # as its default gateway and is not a NIC address on the Mac, so
  # bind(2) would fail with EADDRNOTAVAIL. The security property
  # still holds: bridge100 only exists on the Mac↔Parallels link,
  # hostile peers on public Wi-Fi have no route to 10.211.55.2.
  bindHost = "10.211.55.2";
  port = 8080;

  # Download the GGUF to `.tmp` and atomically rename on success. The
  # naive `if [ -s $path ]; then exit 0` pattern accepts any partial
  # download as "complete" — if launchd reaps curl mid-stream (sleep,
  # crash, throttle), the next agent start skips re-downloading and
  # llama-server bombs out with `tensor data is not within the file
  # bounds`. Storing progress under `.tmp` keeps the final path
  # missing until the download truly finishes, so a restart resumes
  # via curl --continue-at - on the same .tmp file instead of
  # trusting a truncated artifact.
  ensureModel = pkgs.writeShellScript "local-llm-ensure-model" ''
    set -euo pipefail
    if [ -s ${lib.escapeShellArg modelPath} ]; then
      exit 0
    fi
    mkdir -p ${lib.escapeShellArg modelDir}
    echo "Downloading ${model.name} (~22GB) -> ${modelPath}"
    ${pkgs.curl}/bin/curl \
      --location \
      --fail \
      --continue-at - \
      --output ${lib.escapeShellArg "${modelPath}.tmp"} \
      ${lib.escapeShellArg modelUrl}
    mv ${lib.escapeShellArg "${modelPath}.tmp"} ${lib.escapeShellArg modelPath}
  '';

  # Flags here are tuned for Metal on Apple Silicon (M5 Max, 128 GB
  # unified memory) and intentionally diverge from the workstation's
  # ROCm flags in home/services/local-llm.nix. Two notable choices:
  #
  # 1. KV cache stays at default f16 — NOT q8_0 like the workstation.
  #    The workstation quantizes KV because its 16 GB VRAM can't hold
  #    fp16 KV at 196k context; here there's ~18 GiB headroom even
  #    after the 36 GiB Q8 weights, and Metal's flash-attn path is
  #    well-optimized for fp16. Benchmarked on M5 Max with this exact
  #    GGUF + MTP speculative decoding: at depth=24k input,
  #    f16 KV decodes ~21% faster than q8_0 KV (34.8 vs 28.8 tok/s)
  #    and prefills ~20% faster (524 vs 437 tok/s). q8_0 KV is a
  #    VRAM-pressure workaround, not a perf optimization.
  #
  # 2. ubatch-size = batch-size = 2048 — Metal benefits from one big
  #    ubatch per prefill chunk. Pairing must be done together: the
  #    benchmark showed ub=2048 with q8 KV actually regresses ~10%
  #    (mixed dequant paths fight the larger kernels), but f16 KV +
  #    ub=2048 is the global optimum across both shallow and deep
  #    prompts. Workstation keeps ub=1024 because its smaller VRAM
  #    can't comfortably hold the larger activation buffer alongside
  #    the offloaded MoE experts.
  #
  # Threads pinned to 6 = M5 Max P-core count (`hw.perflevel0.physicalcpu`).
  # With --n-gpu-layers 99 the heavy ops are on Metal, but the few
  # CPU-resident ops (sampling, tokenization, MTP draft scoring) run
  # faster on P-cores than the default mixed P+E pool. Explicit pin
  # also stabilizes results across macOS scheduler changes.
  startScript = pkgs.writeShellScript "local-llm-start" ''
    set -euo pipefail
    ${ensureModel}
    exec ${llama-cpp-metal}/bin/llama-server \
      --model ${lib.escapeShellArg modelPath} \
      --alias ${model.id} \
      --host ${bindHost} \
      --port ${toString port} \
      --ctx-size ${toString model.contextWindow} \
      --n-gpu-layers 99 \
      --flash-attn on \
      --batch-size 2048 \
      --ubatch-size 2048 \
      --threads 6 \
      --parallel 1 \
      --cont-batching \
      --spec-type draft-mtp \
      --spec-draft-n-max 3
  '';
in
{
  environment.systemPackages = [
    llama-cpp-metal
    (pkgs.writeShellScriptBin "local-llm-download" ''
      exec ${ensureModel}
    '')
    (pkgs.writeShellScriptBin "local-llm-logs" ''
      exec ${pkgs.coreutils}/bin/tail -F /tmp/local-llm.out /tmp/local-llm.err
    '')
    (pkgs.writeShellScriptBin "local-llm-restart" ''
      set -euo pipefail
      # launchctl is a macOS base-system binary at /bin/launchctl;
      # don't pull a Nix-store cctools just for the kickstart call.
      uid=$(${pkgs.coreutils}/bin/id -u)
      exec /bin/launchctl kickstart -k "gui/$uid/net.faragao.local-llm"
    '')
  ];

  # User-scope LaunchAgent: comes up when the user logs in, has access
  # to ~/.local/share/llm/models/. Mirrors the workstation pattern
  # where `local-llm.service` is a systemd --user unit.
  #
  # The first activation kicks off a ~22GB model download via curl
  # --continue-at -; subsequent starts are instant. launchd will
  # restart the agent on crash; ThrottleInterval=30s prevents a tight
  # loop if `bindHost` isn't up (e.g. Parallels not yet initialized
  # post-boot).
  launchd.user.agents.local-llm = {
    serviceConfig = {
      Label = "net.faragao.local-llm";
      ProgramArguments = [ "${startScript}" ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/tmp/local-llm.out";
      StandardErrorPath = "/tmp/local-llm.err";
      ThrottleInterval = 30;
      ProcessType = "Interactive";
      # LaunchAgents inherit a minimal env from launchd — nothing
      # like the systemd-user case on NixOS where NIX_SSL_CERT_FILE
      # is set globally. Without these the first-launch curl that
      # pulls the GGUF from HuggingFace dies with
      # `SSL certificate ... unable to get local issuer certificate`
      # and the agent restart-loops on exit code 60 forever.
      #
      # We deliberately re-use the combined Avaya + Zscaler + system
      # bundle that darwin/certs.nix exports via environment.variables.
      # Pointing at plain pkgs.cacert would still TLS-fail behind
      # Zscaler's MITM proxy, since the corporate root isn't in the
      # Mozilla store. Reading from `config.environment.variables` also
      # means any future cert added to certs.nix is automatically
      # picked up here — no second source of truth.
      EnvironmentVariables = {
        inherit (config.environment.variables) SSL_CERT_FILE NIX_SSL_CERT_FILE;
      };
    };
  };
}
