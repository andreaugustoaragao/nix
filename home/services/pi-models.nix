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
    builtins.toJSON { providers = cfg.providers; }
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
        unset in settings.json, so subsequent edits via pi's
        /scoped-models UI survive across rebuilds. To re-seed from
        nix, delete the field manually and rebuild.

        Use qualified `provider/id` patterns to be unambiguous when
        the same model id exists on multiple providers (e.g.,
        `anthropic/claude-opus-4-7` vs the corporate gateway's
        `claude-opus-4-7`).
      '';
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
  config = lib.mkIf (cfg.providers != { }) {
    home.activation.piModels = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -eu

      target_models="${config.home.homeDirectory}/.pi/agent/models.json"
      target_settings="${config.home.homeDirectory}/.pi/agent/settings.json"
      mkdir -p "$(dirname "$target_models")"

      rendered="$(cat ${modelsTemplate})"
      ${substitutionSnippets}
      printf '%s' "$rendered" | ${pkgs.jq}/bin/jq . > "$target_models.tmp"
      mv "$target_models.tmp" "$target_models"
      chmod 0600 "$target_models"

      # Seed enabledModels into settings.json only when not already set,
      # preserving anything pi's /scoped-models UI may have written
      # (including the rich {model, thinkingLevel} shape if pi
      # serializes it there).
      enabled_models='${builtins.toJSON cfg.enabledModels}'
      if [[ -f "$target_settings" ]]; then
        existing="$(cat "$target_settings")"
      else
        existing='{}'
      fi
      if ! printf '%s' "$existing" | ${pkgs.jq}/bin/jq -e '.enabledModels' >/dev/null 2>&1; then
        printf '%s' "$existing" \
          | ${pkgs.jq}/bin/jq --argjson em "$enabled_models" '. + {enabledModels: $em}' \
          > "$target_settings.tmp"
        mv "$target_settings.tmp" "$target_settings"
        chmod 0600 "$target_settings"
      fi
    '';
  };
}
