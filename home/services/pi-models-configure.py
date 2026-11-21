#!/usr/bin/env python3
"""Reconcile Pi's managed providers without adopting uncertain user fields."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

LOCAL_SCOPE = "llama-cpp/*-local"
LEGACY_LOCAL_SCOPE_TOKENS = {
    LOCAL_SCOPE,
    "llama-cpp/qwen3.6-35b-a3b-*",
    "llama-cpp/qwen3.6-35b-a3b-q8-local",
}
KNOWN_PRIOR_LOCAL_SEED_LISTS = {
    prefix + (token,) + suffix
    for token in LEGACY_LOCAL_SCOPE_TOKENS
    for prefix, suffix in (
        (("anthropic/claude-opus-4-7", "litellm/*"), ()),
        (("anthropic/claude-opus-4-7",), ("litellm/*",)),
        (("anthropic/claude-opus-4-7",), ()),
    )
}


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def model_of(value):
    if isinstance(value, str):
        return value
    return value.get("model", "") if isinstance(value, dict) else ""


def has_local_scope_string(value):
    return isinstance(value, list) and any(isinstance(x, str) and x in LEGACY_LOCAL_SCOPE_TOKENS for x in value)


def classify_pre_receipt_local_scope(providers, settings, known_hashes):
    enabled = settings.get("enabledModels")
    if not has_local_scope_string(enabled):
        return "absent"
    proven = "llama-cpp" in providers and canonical_hash(providers["llama-cpp"]) in known_hashes
    qwen = any(isinstance(x, str) and x in LEGACY_LOCAL_SCOPE_TOKENS - {LOCAL_SCOPE} for x in enabled)
    seed = all(isinstance(x, str) for x in enabled) and tuple(enabled) in KNOWN_PRIOR_LOCAL_SEED_LISTS
    return "proven_managed" if proven and (qwen or seed) else "unestablished"


def matches_exact_known_legacy(name, provider, known, runtime_url):
    if name == "llama-cpp":
        return canonical_hash(provider) in known.get(name, [])
    if not isinstance(provider, dict):
        return False
    if provider.get("baseUrl") not in {"@@LITELLM_BASE_URL@@", runtime_url} - {None}:
        return False
    return canonical_hash({**provider, "baseUrl": "@@LITELLM_BASE_URL@@"}) in known.get(name, [])


def reconcile(desired, existing_models, existing_settings, receipt, known, runtime_url=None):
    if (not desired["providers"] and desired["defaultModel"] is None
            and not desired["enabledModels"] and not desired["modelThinkingLevels"]
            and receipt is None and existing_models is None and existing_settings is None):
        return None
    models = copy.deepcopy(existing_models) if existing_models is not None else {"providers": {}}
    settings = copy.deepcopy(existing_settings) if existing_settings is not None else {}
    providers = models.setdefault("providers", {})
    previous = receipt or {}
    if receipt is None:
        local_scope = classify_pre_receipt_local_scope(providers, settings, known.get("llama-cpp", []))
        uncertain_thinking = list(settings.get("modelThinkingLevels", {}))
    else:
        local_scope = ("unestablished" if LOCAL_SCOPE in previous.get("unestablishedScopes", []) else
                       "proven_managed" if LOCAL_SCOPE in previous.get("managedScopes", []) else "absent")
        uncertain_thinking = list(previous.get("unestablishedThinkingKeys", []))
    decisions, notices = {}, []
    for name in ("litellm", "llama-cpp"):
        if name in desired["providers"]:
            decisions[name] = "active_managed"
        elif receipt is not None:
            if name not in previous.get("providers", {}):
                decisions[name] = "preserve_unmanaged"
            elif name not in providers or canonical_hash(providers[name]) == previous["providers"][name]:
                decisions[name] = "retire_proven_managed"
            else:
                decisions[name] = "preserve_user_or_unknown"
                notices.append(f"piModels: preserving user-modified provider '{name}' and its settings")
        elif name not in providers:
            decisions[name] = "preserve_unmanaged"
        elif matches_exact_known_legacy(name, providers[name], known, runtime_url):
            decisions[name] = "retire_proven_managed"
        else:
            decisions[name] = "preserve_user_or_unknown"
            notices.append(f"piModels: preserving unestablished legacy provider '{name}' and its settings")

    had_enabled = settings.get("enabledModels") is not None
    for name, decision in decisions.items():
        if decision != "retire_proven_managed":
            continue
        providers.pop(name, None)
        owned_default = previous.get("defaultModel") if receipt is not None else ("litellm/gpt-6.1-sol" if name == "litellm" else None)
        current_default = f"{settings.get('defaultProvider', '')}/{settings.get('defaultModel', '')}"
        if owned_default and owned_default.startswith(name + "/") and current_default == owned_default:
            settings.pop("defaultProvider", None)
            settings.pop("defaultModel", None)
        enabled = settings.get("enabledModels")
        if isinstance(enabled, list):
            if name == "llama-cpp" and local_scope == "proven_managed":
                settings["enabledModels"] = [x for x in enabled if not (isinstance(x, str) and x in LEGACY_LOCAL_SCOPE_TOKENS)]
            elif name == "llama-cpp" and local_scope == "unestablished":
                notices.append("piModels: preserving unestablished scope 'llama-cpp/*-local' in settings.json")
            elif name == "litellm" and (receipt is None or "litellm/*" in previous.get("managedScopes", [])):
                settings["enabledModels"] = [x for x in enabled if x != "litellm/*"]
        thinking = settings.get("modelThinkingLevels")
        if isinstance(thinking, dict):
            for key, value in previous.get("modelThinkingLevels", {}).items():
                if key.startswith(name + "/") and key not in uncertain_thinking and thinking.get(key) == value:
                    del thinking[key]
            if not thinking:
                settings.pop("modelThinkingLevels", None)

    next_provider_hashes = {}
    for name, value in desired["providers"].items():
        providers[name] = copy.deepcopy(value)
        next_provider_hashes[name] = canonical_hash(value)
    enabled = settings.get("enabledModels")
    if LOCAL_SCOPE in desired["enabledModels"] and isinstance(enabled, list):
        settings["enabledModels"] = [
            LOCAL_SCOPE if isinstance(x, str) and x in LEGACY_LOCAL_SCOPE_TOKENS else
            {**x, "model": LOCAL_SCOPE} if isinstance(x, dict) and model_of(x) in LEGACY_LOCAL_SCOPE_TOKENS else x
            for x in enabled
        ]
    managed_scopes, uncertain_scopes = [], []
    if "litellm/*" in desired["enabledModels"] and isinstance(settings.get("enabledModels"), list):
        settings["enabledModels"] = [x for x in settings["enabledModels"] if not model_of(x).startswith("litellm/")] + ["litellm/*"]
        managed_scopes.append("litellm/*")
    if not had_enabled and desired["enabledModels"]:
        settings["enabledModels"] = list(desired["enabledModels"])
        managed_scopes = [x for x in ("litellm/*", LOCAL_SCOPE) if x in desired["enabledModels"]]
    elif local_scope == "unestablished" and has_local_scope_string(settings.get("enabledModels")):
        uncertain_scopes.append(LOCAL_SCOPE)
        if receipt is None:
            notices.append("piModels: recording unestablished scope 'llama-cpp/*-local' in managed-state.json")
    elif LOCAL_SCOPE in desired["enabledModels"] and local_scope == "proven_managed":
        managed_scopes.append(LOCAL_SCOPE)
    next_default = desired["defaultModel"]
    if next_default is not None:
        settings["defaultProvider"], settings["defaultModel"] = next_default.split("/", 1)
    next_thinking = {}
    for key, value in desired["modelThinkingLevels"].items():
        if key not in uncertain_thinking:
            settings.setdefault("modelThinkingLevels", {})[key] = value
            next_thinking[key] = value
    next_receipt = {
        "version": 1, "providers": next_provider_hashes, "defaultModel": next_default,
        "managedScopes": managed_scopes, "unestablishedScopes": uncertain_scopes,
        "unestablishedThinkingKeys": uncertain_thinking, "modelThinkingLevels": next_thinking,
    }
    return models, settings, next_receipt, notices


def load(path):
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {path.name}")
    return value


def atomic_write(path, value):
    if path.exists() and load(path) == value and not path.is_symlink():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".pi-models-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    parser = argparse.ArgumentParser()
    for name in ("desired", "models-file", "settings-file", "receipt-file", "known-legacy"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--litellm-base-url-secret", type=Path)
    args = parser.parse_args()
    runtime_url = None
    if args.litellm_base_url_secret is not None:
        try:
            runtime_url = args.litellm_base_url_secret.read_text().strip() or None
        except OSError:
            pass
    result = reconcile(load(args.desired), load(args.models_file), load(args.settings_file),
                       load(args.receipt_file), load(args.known_legacy), runtime_url)
    if result is None:
        return
    models, settings, receipt, notices = result
    if models.get("providers") == {} and set(models) <= {"providers"}:
        args.models_file.unlink(missing_ok=True)
    else:
        atomic_write(args.models_file, models)
    if settings or args.settings_file.exists():
        atomic_write(args.settings_file, settings)
    atomic_write(args.receipt_file, receipt)
    for notice in notices:
        print(notice, file=sys.stderr)


if __name__ == "__main__":
    main()
