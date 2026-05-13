{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  llama-cpp-rocm = unstable-pkgs.llama-cpp.override {
    rocmSupport = true;
    rocmGpuTargets = [ "gfx1100" ];
  };

  model = {
    id = "qwen3.6-35b-a3b-local";
    name = "Qwen3.6 35B A3B Local";
    repo = "unsloth/Qwen3.6-35B-A3B-GGUF";
    file = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
    contextWindow = 196608;
    maxTokens = 8192;
  };

  modelDir = "${config.home.homeDirectory}/.local/share/llm/models";
  modelPath = "${modelDir}/${model.file}";
  modelUrl = "https://huggingface.co/${model.repo}/resolve/main/${model.file}?download=true";

  commonPath = pkgs.lib.makeBinPath [
    pkgs.coreutils
    pkgs.curl
    pkgs.gnugrep
    pkgs.procps
    pkgs.systemd
    llama-cpp-rocm
  ];

  ensureLocalLlm = ''
    set -euo pipefail

    if [ ! -s ${pkgs.lib.escapeShellArg modelPath} ]; then
      local-llm-download
    fi

    ${pkgs.systemd}/bin/systemctl --user start local-llm.service

    ready=0
    for _ in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8080/v1/models >/dev/null 2>&1; then
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
  '';
in
{
  home.packages = [
    (pkgs.writeShellScriptBin "local-llm-download" ''
      set -euo pipefail

      mkdir -p ${pkgs.lib.escapeShellArg modelDir}
      if [ -s ${pkgs.lib.escapeShellArg modelPath} ]; then
        echo "Model already exists: ${modelPath}"
        exit 0
      fi

      echo "Downloading ${model.name}"
      echo "Target: ${modelPath}"
      ${pkgs.curl}/bin/curl \
        --location \
        --fail \
        --continue-at - \
        --output ${pkgs.lib.escapeShellArg modelPath} \
        ${pkgs.lib.escapeShellArg modelUrl}
    '')
    (pkgs.writeShellScriptBin "local-llm-start" ''
      set -euo pipefail

      if [ ! -s ${pkgs.lib.escapeShellArg modelPath} ]; then
        local-llm-download
      fi

      exec ${pkgs.systemd}/bin/systemctl --user start local-llm.service
    '')
    (pkgs.writeShellScriptBin "local-llm-logs" ''
      exec ${pkgs.systemd}/bin/journalctl --user -u local-llm.service -f
    '')
    (pkgs.writeShellScriptBin "local-pi" ''
      ${ensureLocalLlm}
      exec pi --model llama-cpp/${model.id} "$@"
    '')
    (pkgs.writeShellScriptBin "local-qwen-code" ''
      ${ensureLocalLlm}

      export OPENAI_API_KEY=local
      export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
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

  home.sessionVariables.LOCAL_LLAMA_CPP = "${llama-cpp-rocm}";

  home.file.".local/share/llm/models/.keep".text = "";

  home.file.".pi/agent/models.json".text = builtins.toJSON {
    providers.llama-cpp = {
      baseUrl = "http://127.0.0.1:8080/v1";
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

  systemd.user.services.local-llm = {
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
      ExecStartPre = "${pkgs.coreutils}/bin/test -s ${pkgs.lib.escapeShellArg modelPath}";
      ExecStart = ''
        ${llama-cpp-rocm}/bin/llama-server \
          --model ${pkgs.lib.escapeShellArg modelPath} \
          --alias ${model.id} \
          --host 127.0.0.1 \
          --port 8080 \
          --ctx-size ${toString model.contextWindow} \
          --n-gpu-layers 99 \
          --cpu-moe \
          --flash-attn on \
          --cache-type-k q8_0 \
          --cache-type-v q8_0 \
          --batch-size 2048 \
          --ubatch-size 1024 \
          --threads 16 \
          --parallel 1 \
          --cont-batching
      '';
      Restart = "on-failure";
      RestartSec = "5s";
    };

    Install = { };
  };
}
