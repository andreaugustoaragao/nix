{
  config,
  pkgs,
  lib,
  owner,
  homePrefix,
  ...
}:

let
  # Package Unsloth's official b12651-mix-c7059d6 macOS arm64 prebuilt
  # (commit d426a3774): includes the inkling2 looped-layer + MoE cache +
  # fused DSpark (device-buffer target features) + chunked/banded Metal FA
  # PR stack. Exclusive interleaved A/B on mac-work (M5 Max) against
  # b12588-mix-c0c3de8 + --spec-draft-n-max 3: +18-29% prefill (5K/20K),
  # +18-24% decode (temp=1.0/greedy), and -12% short TTFT.
  llama-cpp-metal = pkgs.stdenvNoCC.mkDerivation {
    pname = "llama-cpp-unsloth";
    version = "12651-mix-c7059d6";
    src = pkgs.fetchurl {
      url = "https://github.com/unslothai/llama.cpp/releases/download/b12651-mix-c7059d6/llama-b12651-mix-c7059d6-bin-macos-arm64.tar.gz";
      sha256 = "fb1eb013113962d2e874e5d93b4db912549c38ddc7285acc247b49e1300e1fdd";
    };
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      cp -a . "$out/bin/"
      runHook postInstall
    '';
  };

  model = {
    id = "inkling-2-mini-local";
    name = "Inkling 2 Mini Local (UD-Q4_K_XL + DSpark)";
    repo = "unsloth/Inkling-2-Mini-GGUF";
    # Pinned HF revision so fresh hosts download the exact benchmarked
    # artifacts — notably the faster 402 MB padded-vocab DSpark drafter
    # (renamed to *_Old.gguf upstream, sha256 2ec78510...) rather than
    # the heavier 504 MB mainline drafter.
    hfRev = "8078d149286eec7193795413b9e0643da6d11fa1";
    file = "Inkling-2-Mini-UD-Q4_K_XL.gguf";
    mmprojFile = "mmproj-F16.gguf";
    draftFile = "dspark-Inkling-2-Mini-Q8_0.gguf";
    draftRemoteFile = "dspark-Inkling-2-Mini-Q8_0_Old.gguf";
    contextWindow = 262144;
    maxTokens = 8192;
  };

  homeDir = "${homePrefix}/${owner.name}";
  modelDir = "${homeDir}/.local/share/llm/models";
  modelPath = "${modelDir}/${model.file}";
  modelUrl = "https://huggingface.co/${model.repo}/resolve/${model.hfRev}/${model.file}?download=true";
  mmprojPath = "${modelDir}/${model.mmprojFile}";
  mmprojUrl = "https://huggingface.co/${model.repo}/resolve/${model.hfRev}/${model.mmprojFile}?download=true";
  draftPath = "${modelDir}/${model.draftFile}";
  draftUrl = "https://huggingface.co/${model.repo}/resolve/${model.hfRev}/${model.draftRemoteFile}?download=true";

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
    mkdir -p ${lib.escapeShellArg modelDir}

    if [ ! -s ${lib.escapeShellArg modelPath} ]; then
      echo "Downloading ${model.name} (~16.4GiB) -> ${modelPath}"
      ${pkgs.curl}/bin/curl \
        --location \
        --fail \
        --continue-at - \
        --output ${lib.escapeShellArg "${modelPath}.tmp"} \
        ${lib.escapeShellArg modelUrl}
      mv ${lib.escapeShellArg "${modelPath}.tmp"} ${lib.escapeShellArg modelPath}
    fi

    if [ ! -s ${lib.escapeShellArg mmprojPath} ]; then
      echo "Downloading ${model.name} vision projector (~610MiB) -> ${mmprojPath}"
      ${pkgs.curl}/bin/curl \
        --location \
        --fail \
        --continue-at - \
        --output ${lib.escapeShellArg "${mmprojPath}.tmp"} \
        ${lib.escapeShellArg mmprojUrl}
      mv ${lib.escapeShellArg "${mmprojPath}.tmp"} ${lib.escapeShellArg mmprojPath}
    fi

    if [ ! -s ${lib.escapeShellArg draftPath} ]; then
      echo "Downloading ${model.name} DSpark drafter (~384MiB) -> ${draftPath}"
      ${pkgs.curl}/bin/curl \
        --location \
        --fail \
        --continue-at - \
        --output ${lib.escapeShellArg "${draftPath}.tmp"} \
        ${lib.escapeShellArg draftUrl}
      mv ${lib.escapeShellArg "${draftPath}.tmp"} ${lib.escapeShellArg draftPath}
    fi
  '';

  # Inkling 2 Mini on Metal (M5 Max hill-climb):
  # - Keep --ubatch-size 512 (beats 256/1024/2048 on prefill and bounds the
  #   relative-bias compute buffer at 262K ctx) and F16 KV (q8_0 KV halves
  #   Metal decode/prefill on this 8-full-layer SWA hybrid).
  # - Use --spec-draft-n-max 1: on this 128-expert top-8 MoE, k=3 amplifies
  #   active expert reads (~22.8% vs 6.25%) beyond temp=1.0 acceptance
  #   (making k=3 slower than no drafter), while k=1 wins both greedy and
  #   temp=1.0 (+18-24% vs b12588 k=3).
  startScript = pkgs.writeShellScript "local-llm-start" ''
    set -euo pipefail
    ${ensureModel}
    exec ${llama-cpp-metal}/bin/llama-server \
      --model ${lib.escapeShellArg modelPath} \
      --mmproj ${lib.escapeShellArg mmprojPath} \
      --model-draft ${lib.escapeShellArg draftPath} \
      --spec-type draft-dspark \
      --spec-draft-n-max 1 \
      --n-gpu-layers-draft 99 \
      --alias ${model.id} \
      --host ${bindHost} \
      --port ${toString port} \
      --ctx-size ${toString model.contextWindow} \
      --n-gpu-layers 99 \
      --flash-attn on \
      --batch-size 2048 \
      --ubatch-size 512 \
      --threads 6 \
      --parallel 1 \
      --cont-batching \
      --jinja \
      --temp 1.0 \
      --top-p 1.0 \
      --top-k 0 \
      --min-p 0.0
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
  # The first activation kicks off a ~17.4GiB model + projector + drafter
  # download via curl --continue-at -; subsequent starts are instant.
  # launchd will restart the agent on crash; ThrottleInterval=30s
  # prevents a tight loop if `bindHost` isn't up (e.g. Parallels not
  # yet initialized post-boot).
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
