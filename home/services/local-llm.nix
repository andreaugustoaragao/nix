{
  config,
  pkgs,
  lib,
  inputs,
  isWorkstation,
  ...
}:

let
  # Shared model identity — same on workstation (which hosts the
  # server) and on the dev VMs (which point their clients at the Mac).
  # `model.id` is the alias the OpenAI-compat API exposes, so
  # `~/.pi/agent/models.json` and the wrappers below resolve the same
  # name regardless of which host actually serves the weights.
  model = {
    id = "qwen3.6-35b-a3b-local";
    name = "Qwen3.6 35B A3B Local";
    repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
    file = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
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
          ${pkgs.curl}/bin/curl \
            --location \
            --fail \
            --continue-at - \
            --output ${lib.escapeShellArg modelPath} \
            ${lib.escapeShellArg modelUrl}
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
        (pkgs.writeShellScriptBin "local-pi" ''
          ${ensureLocalLlm}
          exec pi --model llama-cpp/${model.id} "$@"
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

    # `home.file` is plain attrset of file-spec attrsets, so we can
    # compose via lib.optionalAttrs + // to keep workstation-only
    # entries (`.keep` for the model dir) cleanly separated from the
    # always-present client config (`models.json`).
    file =
      lib.optionalAttrs isWorkstation {
        ".local/share/llm/models/.keep".text = "";
      }
      // {
        ".pi/agent/models.json".text = builtins.toJSON {
          providers.llama-cpp = {
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
        };
      };
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
