{
  config,
  pkgs,
  lib,
  inputs,
  isWorkstation,
  ...
}:

let
  # Model identity differs per host because the quant does:
  #   - workstation (16 GB VRAM, ROCm): forced into Q4_K_XL by
  #     `--n-cpu-moe 28`. Alias `qwen3.6-35b-a3b-local`.
  #   - dev VMs (client → mac-work, 128 GB unified memory): Q8_K_XL
  #     of the same MoE, near-FP16 quality. Alias
  #     `qwen3.6-35b-a3b-q8-local`, kept distinct so pi history
  #     reflects which quant served a turn.
  # The `repo`/`file` fields are only consulted on the server side
  # (workstation systemd unit + download script); VM clients only
  # care about `id`, `contextWindow`, `maxTokens` for models.json.
  model =
    if isWorkstation then
      {
        id = "qwen3.6-35b-a3b-local";
        name = "Qwen3.6 35B A3B Local";
        repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
        file = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
        contextWindow = 196608;
        maxTokens = 8192;
      }
    else
      {
        id = "qwen3.6-35b-a3b-q8-local";
        name = "Qwen3.6 35B A3B Local (Q8)";
        repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
        file = "Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf";
        contextWindow = 196608;
        maxTokens = 8192;
      };

  # Where the OpenAI-compat API lives from this host's POV.
  # workstation runs llama-server itself; VM hosts reach the mac-work
  # LaunchAgent (darwin/services/local-llm.nix) over the Parallels
  # shared network via mDNS.
  baseUrl = if isWorkstation then "http://127.0.0.1:8080/v1" else "http://mac-work.local:8080/v1";

  # ===== Workstation-only: locally-built llama.cpp + systemd service =====

  # Pinned to a nixpkgs rev with llama-cpp b9190 (first build with MTP
  # speculative decoding). See flake.nix nixpkgs-llama input.
  llama-pkgs = import inputs.nixpkgs-llama {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  llama-cpp-rocm = llama-pkgs.llama-cpp.override {
    rocmSupport = true;
    rocmGpuTargets = [ "gfx1100" ];
  };

  modelDir = "${config.home.homeDirectory}/.local/share/llm/models";
  modelPath = "${modelDir}/${model.file}";
  modelUrl = "https://huggingface.co/${model.repo}/resolve/main/${model.file}?download=true";

  commonPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.curl
    pkgs.gnugrep
    pkgs.procps
    pkgs.systemd
    llama-cpp-rocm
  ];

  # Probe / start helper shared by `local-pi` and `local-qwen-code`.
  # On workstation this kicks the local systemd user service and polls
  # 127.0.0.1; on VM hosts it just probes mac-work.local and bails
  # loudly if the Mac-side LaunchAgent isn't healthy — no point in
  # exec'ing `pi` against a black hole.
  ensureLocalLlm =
    if isWorkstation then
      ''
        set -euo pipefail

        if [ ! -s ${lib.escapeShellArg modelPath} ]; then
          local-llm-download
        fi

        ${pkgs.systemd}/bin/systemctl --user start local-llm.service

        ready=0
        for _ in $(seq 1 60); do
          if ${pkgs.curl}/bin/curl -fsS ${baseUrl}/models >/dev/null 2>&1; then
            ready=1
            break
          fi
          sleep 1
        done

        if [ "$ready" = 1 ]; then
          true
        else
        echo "local-llm.service did not become ready within 60s" >&2
        echo "Run: local-llm-logs" >&2
        exit 1
        fi
      ''
    else
      ''
        set -euo pipefail

        if ! ${pkgs.curl}/bin/curl -fsS --max-time 3 ${baseUrl}/models >/dev/null 2>&1; then
          echo "Remote LLM at ${baseUrl} is unreachable." >&2
          echo "Check mac-work's LaunchAgent:" >&2
          echo "  ssh mac-work.local 'launchctl print gui/\$(id -u)/net.faragao.local-llm'" >&2
          echo "  ssh mac-work.local 'tail -n 50 /tmp/local-llm.err'" >&2
          exit 1
        fi
      '';
in
{
  home = {
    packages =
      # Server-side wrappers only ship where the server actually runs.
      # On VM hosts these are no-ops at best and misleading at worst
      # (`local-llm-logs` would tail a non-existent journal unit).
      lib.optionals isWorkstation [
        (pkgs.writeShellScriptBin "local-llm-download" ''
          set -euo pipefail

          mkdir -p ${lib.escapeShellArg modelDir}
          if [ -s ${lib.escapeShellArg modelPath} ]; then
            echo "Model already exists: ${modelPath}"
            exit 0
          fi

          echo "Downloading ${model.name}"
          echo "Target: ${modelPath}"
          # Download to `.tmp` and atomically rename on success, mirroring
          # the Darwin sibling. The naive `[ -s $path ]` gate treats any
          # partial download as complete, so an interrupted curl would leave
          # a truncated GGUF that llama-server rejects with "tensor data is
          # not within the file bounds". --continue-at - resumes the .tmp.
          ${pkgs.curl}/bin/curl \
            --location \
            --fail \
            --continue-at - \
            --output ${lib.escapeShellArg "${modelPath}.tmp"} \
            ${lib.escapeShellArg modelUrl}
          mv ${lib.escapeShellArg "${modelPath}.tmp"} ${lib.escapeShellArg modelPath}
        '')
        (pkgs.writeShellScriptBin "local-llm-start" ''
          set -euo pipefail

          if [ ! -s ${lib.escapeShellArg modelPath} ]; then
            local-llm-download
          fi

          exec ${pkgs.systemd}/bin/systemctl --user start local-llm.service
        '')
        (pkgs.writeShellScriptBin "local-llm-logs" ''
          exec ${pkgs.systemd}/bin/journalctl --user -u local-llm.service -f
        '')
      ]
      # Client wrappers ship everywhere — same name, same UX, just a
      # different baseUrl baked in. Keeps muscle memory portable
      # between workstation and dev VMs.
      ++ [
        # Health-check wrapper: probe the local llama.cpp server (or
        # mac-work LaunchAgent on VM hosts) for readiness, then exec
        # bare `pi`. Use Ctrl+P / Shift+Ctrl+P inside the session to
        # cycle to the local model (its qualified ID is included in
        # services.piModels.enabledModels via home/cli/pi.nix). Pass
        # --model 'llama-cpp/qwen3.6-35b-a3b-*' if you want to start
        # pinned to local instead of cycling there manually.
        (pkgs.writeShellScriptBin "local-pi" ''
          ${ensureLocalLlm}
          exec pi "$@"
        '')
        (pkgs.writeShellScriptBin "local-qwen-code" ''
          ${ensureLocalLlm}

          export OPENAI_API_KEY=local
          export OPENAI_BASE_URL=${baseUrl}
          export OPENAI_MODEL=${model.id}

          if command -v qwen >/dev/null 2>&1; then
            exec qwen "$@"
          fi
          if command -v qwen-code >/dev/null 2>&1; then
            exec qwen-code "$@"
          fi

          echo "qwen-code is not installed yet. Open a new shell after Home Manager activation, or run install-qwen-code." >&2
          exit 1
        '')
      ];

    sessionVariables = lib.optionalAttrs isWorkstation {
      LOCAL_LLAMA_CPP = "${llama-cpp-rocm}";
    };

    # Workstation also owns the model-store directory; client hosts
    # don't need it. The models.json contribution is unconditional
    # (every host with this module gets a llama-cpp entry pointing
    # either at 127.0.0.1 or mac-work.local).
    file = lib.optionalAttrs isWorkstation {
      ".local/share/llm/models/.keep".text = "";
    };
  };

  # Contribute the llama-cpp provider to the aggregator. The
  # aggregator (home/services/pi-models.nix) renders the merged
  # provider set into ~/.pi/agent/models.json at activation time.
  services.piModels.providers.llama-cpp = {
    inherit baseUrl;
    api = "openai-completions";
    apiKey = "local";
    compat = {
      supportsDeveloperRole = false;
      supportsReasoningEffort = false;
      supportsUsageInStreaming = false;
    };
    models = [
      {
        inherit (model)
          id
          name
          contextWindow
          maxTokens
          ;
        reasoning = false;
        input = [ "text" ];
        cost = {
          input = 0;
          output = 0;
          cacheRead = 0;
          cacheWrite = 0;
        };
      }
    ];
  };

  # Server-side systemd unit — only on workstation. On VM hosts the
  # equivalent role is filled by mac-work's launchd LaunchAgent (see
  # darwin/services/local-llm.nix).
  systemd.user.services.local-llm = lib.mkIf isWorkstation {
    Unit = {
      Description = "Local llama.cpp coding model server";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };

    Service = {
      Type = "exec";
      Environment = [
        "PATH=${commonPath}"
        "HIP_VISIBLE_DEVICES=0"
        "ROCR_VISIBLE_DEVICES=0"
        "GPU_DEVICE_ORDINAL=0"
        "HSA_OVERRIDE_GFX_VERSION=11.0.0"
        "ROC_ENABLE_PRE_VEGA=1"
      ];
      ExecStartPre = "${pkgs.coreutils}/bin/test -s ${lib.escapeShellArg modelPath}";
      ExecStart = ''
        ${llama-cpp-rocm}/bin/llama-server \
          --model ${lib.escapeShellArg modelPath} \
          --alias ${model.id} \
          --host 127.0.0.1 \
          --port 8080 \
          --ctx-size ${toString model.contextWindow} \
          --n-gpu-layers 99 \
          -fit off \
          --n-cpu-moe 28 \
          --flash-attn on \
          --cache-type-k q8_0 \
          --cache-type-v q8_0 \
          --batch-size 2048 \
          --ubatch-size 1024 \
          --threads 24 \
          --parallel 1 \
          --cont-batching \
          --spec-type draft-mtp \
          --spec-draft-n-max 3
      '';
      Restart = "on-failure";
      RestartSec = "5s";
    };

    Install = { };
  };
}
