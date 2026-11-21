{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.piModels;

  # Render providers to JSON in the Nix store with placeholders left
  # in place. Substitution into the user-readable file happens at
  # activation time so secret base URLs (corporate gateway hostnames)
  # never enter /nix/store.
  modelsTemplate = pkgs.writeText "pi-models.json.template" (
    builtins.toJSON {
      inherit (cfg)
        providers
        defaultModel
        enabledModels
        modelThinkingLevels
        ;
    }
  );

  # Per-placeholder substitution snippets, mirroring the codex.nix
  # @@LITELLM_BASE_URL@@ pattern. Missing or "placeholder"-valued
  # secret files leave the marker in place so the resulting
  # models.json fails loudly when those models are exercised, rather
  # than silently appearing functional.
  substitutionSnippets = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (placeholder: secretPath: ''
      if [[ -r "${secretPath}" ]]; then
        candidate="$(cat "${secretPath}")"
        if [[ -n "$candidate" && "$candidate" != "placeholder" ]]; then
          rendered="$(printf '%s' "$rendered" | ${pkgs.gnused}/bin/sed "s|${placeholder}|$candidate|g")"
        fi
      fi
    '') cfg.baseUrlSubstitutions
  );
  knownLegacy = pkgs.writeText "pi-models-known-legacy.json" (
    builtins.toJSON {
      llama-cpp =
        map
          (
            profile:
            builtins.hashString "sha256" (
              builtins.toJSON
                (import ./local-llm.nix {
                  inherit config lib pkgs;
                  inherit (profile) isWorkstation isDarwinHost;
                  hostName = "";
                  llama-pkgs = { };
                }).services.piModels.providers.llama-cpp
            )
          )
          [
            {
              isWorkstation = true;
              isDarwinHost = false;
            }
            {
              isWorkstation = false;
              isDarwinHost = false;
            }
            {
              isWorkstation = false;
              isDarwinHost = true;
            }
          ];
      litellm = [
        "d28ad4cc92b9ea14d5514c2d320b966ab34fb0559bb0f771eb5f93b176492d03"
        (builtins.hashString "sha256" (
          builtins.toJSON (import ./litellm.nix { }).services.piModels.providers.litellm
        ))
      ];
    }
  );
in
{
  # Aggregator for ~/.pi/agent/models.json. Contributing modules
  # (services/litellm.nix, services/local-llm.nix, ...) append entries
  # under `services.piModels.providers`; this module renders the merged
  # set to disk with placeholder substitution for secret base URLs.
  options.services.piModels = {
    providers = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = ''
        Pi provider entries materialized into ~/.pi/agent/models.json.
        Keyed by provider name; values pass through to pi as JSON.
        See pi-coding-agent/docs/models.md for the schema.

        Each provider must be defined by exactly one contributing
        module — the option type is shallow-merging.
      '';
    };

    enabledModels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Seed list for ~/.pi/agent/settings.json -> enabledModels.
        Drives pi's Ctrl+P / Shift+Ctrl+P cycle (the "scoped models"
        selector). Written only on activations that find the field
        unset in settings.json. When this list contains litellm/*, activation
        keeps the full WebAI scope enabled and preserves other provider scopes.
        Otherwise subsequent edits via pi's /scoped-models UI survive rebuilds.

        Use qualified `provider/id` patterns to be unambiguous when
        the same model id exists on multiple providers (e.g.,
        `anthropic/claude-opus-4-7` vs the corporate gateway's
        `claude-opus-4-7`).
      '';
    };

    defaultModel = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[^/]+/[^/]+");
      default = null;
      description = ''
        Qualified provider/model selected by plain pi. Null leaves pi's
        existing default untouched.
      '';
    };

    modelThinkingLevels = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "off"
          "minimal"
          "low"
          "medium"
          "high"
          "xhigh"
        ]
      );
      default = { };
      description = "Managed per-model thinking levels for Pi settings.";
    };

    baseUrlSubstitutions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Map of @@PLACEHOLDER@@ -> /run/secrets/<file> paths used to
        keep secret base URLs (corporate gateway hostnames) out of
        /nix/store. Substituted into the rendered models.json at
        activation time. Mirrors the @@LITELLM_BASE_URL@@ pattern
        in home/cli/codex.nix.
      '';
    };
  };

  # Activation runs after writeBoundary so any prior /nix/store
  # symlink at ~/.pi/agent/models.json (from the old direct-write in
  # local-llm.nix) is already gone by the time we materialize the new
  # regular file.
  config.home.activation.piModels = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -eu
    target_models="${config.home.homeDirectory}/.pi/agent/models.json"
    target_settings="${config.home.homeDirectory}/.pi/agent/settings.json"
    desired_tmp="$(mktemp)"
    trap 'rm -f "$desired_tmp"' EXIT
    chmod 0600 "$desired_tmp"
    rendered="$(cat ${modelsTemplate})"
    ${substitutionSnippets}
    printf '%s' "$rendered" > "$desired_tmp"
    ${pkgs.python3}/bin/python3 ${./pi-models-configure.py} \
      --desired "$desired_tmp" \
      --models-file "$target_models" \
      --settings-file "$target_settings" \
      --receipt-file "${config.xdg.stateHome}/pi-models/managed-state.json" \
      --known-legacy ${knownLegacy} \
      --litellm-base-url-secret /run/secrets/litellm_base_url
    rm -f "$desired_tmp"
    trap - EXIT
  '';
}
