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

  # Identical to home/services/local-llm.nix so `local-pi` clients
  # resolve the same `${model.id}` to the same weights regardless of
  # which host happens to be serving them today.
  model = {
    id = "qwen3.6-35b-a3b-local";
    name = "Qwen3.6 35B A3B Local";
    repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
    file = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
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
      --cache-type-k q8_0 \
      --cache-type-v q8_0 \
      --batch-size 2048 \
      --ubatch-size 1024 \
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
