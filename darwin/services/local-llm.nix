{
  config,
  pkgs,
  lib,
  inputs,
  # Reuse the pinned nixpkgs llama.cpp derivation, replacing only its
  # source with PrismML's fork on Darwin. Linux keeps upstream llama.cpp.
  llama-pkgs,
  owner,
  homePrefix,
  ...
}:

let
  # Bonsai's PQ2_0 tensors and Hadamard activation transform are only
  # implemented by PrismML's fork. Keep using nixpkgs' Darwin build
  # recipe so Metal and Accelerate are configured in the usual way.
  llama-cpp-metal = llama-pkgs.llama-cpp.overrideAttrs (_oldAttrs: {
    pname = "llama-cpp-prism";
    version = "10709";
    src = inputs.prism-llama;
    npmDepsHash = "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=";
  });

  # PQ2_0 is PrismML's preferred Apple-Silicon packing. It is slightly
  # larger than PTQ1_0 but has cheaper unpacking and is the variant for
  # which PrismML publishes M5 Max Metal results.
  model = {
    id = "bonsai-2-27b-local";
    name = "Bonsai 2 27B Local (PQ2_0)";
    repo = "prism-ml/Ternary-Bonsai-2-27B-gguf";
    file = "Ternary-Bonsai-2-27B-PQ2_0.gguf";
    contextWindow = 262144;
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
    echo "Downloading ${model.name} (~7.2GB) -> ${modelPath}"
    ${pkgs.curl}/bin/curl \
      --location \
      --fail \
      --continue-at - \
      --output ${lib.escapeShellArg "${modelPath}.tmp"} \
      ${lib.escapeShellArg modelUrl}
    mv ${lib.escapeShellArg "${modelPath}.tmp"} ${lib.escapeShellArg modelPath}
  '';

  # PrismML's published Metal invocation uses full GPU offload and flash
  # attention. Keep the existing large prefill batches and six P-core
  # worker threads; unlike the old Qwen MTP model, Bonsai has no embedded
  # draft head, so speculative-decoding flags must not be passed.
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
      --jinja
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
  # The first activation kicks off a ~7.2GB model download via curl
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
      # We deliberately re-use the combined corporate + system bundle
      # that darwin/certs.nix exports via environment.variables.
      # Pointing at plain pkgs.cacert would still TLS-fail behind the
      # corporate MITM proxy, since the proxy's root isn't in the
      # Mozilla store. Reading from `config.environment.variables` also
      # means any future cert added to certs.nix is automatically
      # picked up here — no second source of truth.
      EnvironmentVariables = {
        inherit (config.environment.variables) SSL_CERT_FILE NIX_SSL_CERT_FILE;
      };
    };
  };
}
