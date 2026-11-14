{
  config,
  lib,
  pkgs,
  personalOnly,
  isServer ? false,
  ...
}:

let
  piProviders = config.services.piModels.providers;
  compatiblePackage = "@opencode/ai/providers/openai-compatible";

  # Reuse Pi's WebAI and host-specific models, including protocol and limits.
  # Credentials remain runtime file references.
  piModels =
    provider:
    lib.listToAttrs (
      map (model: {
        name = model.id;
        value = {
          inherit (model) name;
          capabilities = {
            tools = true;
            inherit (model) input;
            output = [ "text" ];
          }
          // lib.optionalAttrs (model.reasoning or false) { reasoning.supported = true; };
          limit = {
            context = model.contextWindow;
            output = model.maxTokens;
          };
        }
        // lib.optionalAttrs ((model.api or provider.api) == "openai-responses") {
          package = "@opencode/ai/providers/openai/responses";
          body.store = false;
        };
      }) provider.models
    );

in
{
  config = lib.mkIf (!isServer) {
    xdg.configFile."opencode/AGENTS.md".text = import ./browser-instructions.nix;

    # Keep CLI preferences writable for OpenCode and terminal integrations.
    home.activation.opencodeCliSettings =
      lib.hm.dag.entryAfter
        [
          "linkGeneration"
          "herdrIntegrations"
        ]
        ''
          run ${lib.getExe pkgs.python3} - ${lib.escapeShellArg "${config.xdg.configHome}/opencode/cli.json"} <<'PY'
          import json
          import os
          from pathlib import Path
          import sys
          import tempfile

          path = Path(sys.argv[1])
          settings = json.loads(path.read_text()) if path.exists() else {}
          settings.setdefault("$schema", "https://opencode.ai/v2/cli.json")
          settings.setdefault("session", {})["sidebar"] = "hide"
          settings["session"]["permissions"] = "autoaccept"
          settings.setdefault("tabs", {})["mode"] = "off"
          content = json.dumps(settings, indent=2) + "\n"
          if not path.exists() or path.read_text() != content:
              path.parent.mkdir(parents=True, exist_ok=True)
              descriptor, temporary = tempfile.mkstemp(prefix=".cli.json.", dir=path.parent)
              try:
                  with os.fdopen(descriptor, "w") as output:
                      output.write(content)
                  os.replace(temporary, path)
              finally:
                  Path(temporary).unlink(missing_ok=True)
          PY
        '';

    xdg.configFile."opencode/opencode.jsonc".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = if personalOnly then "openai/gpt-6-sol" else "litellm/gpt-6-astra";
      update = "disable"; # The executable is managed by Nix.
      permissions = [
        {
          action = "*";
          resource = "*";
          effect = "allow";
        }
      ];
      mcp.servers =
        lib.optionalAttrs (!personalOnly) {
          atlassian = {
            type = "remote";
            url = "https://mcp.atlassian.com/v2/mcp";
          };
        }
        // config.my.sharedVault.opencodeServers;
      providers =
        lib.optionalAttrs (!personalOnly) {
          litellm = {
            name = "LiteLLM";
            package = compatiblePackage;
            settings = {
              baseURL = "{file:/run/secrets/litellm_base_url}";
              apiKey = "{file:/run/secrets/litellm_api_key}";
            };
            models = piModels piProviders.litellm;
          };

          # Pi routes Claude directly to Anthropic, rather than LiteLLM.
          # Keep the built-in catalog so new Claude models remain available.
          anthropic.settings.apiKey = "{file:/run/secrets/anthropic_api_key}";
        }
        // lib.optionalAttrs (piProviders ? llama-cpp) {
          llama-cpp = {
            name = "llama.cpp (local)";
            package = compatiblePackage;
            settings = {
              baseURL = piProviders.llama-cpp.baseUrl;
              apiKey = piProviders.llama-cpp.apiKey;
            };
            models = piModels piProviders.llama-cpp;
          };
        };
    };
  };
}
