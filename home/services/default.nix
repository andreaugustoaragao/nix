{
  lib,
  hostName,
  isDarwinHost ? false,
  isServer ? false,
  ...
}:

# Platform-gated user services. The Linux entries below are all
# systemd-user-flavored (notes-sync, fulcrum, darkman, local-llm) and
# would error at evaluation on Darwin where `systemd.user.services` is
# undefined. The Darwin notes-sync is a structurally separate launchd
# agent in notes-sync-darwin.nix.
#
# fulcrum is additionally gated to non-server hosts: its systemd
# unit unconditionally reads /run/secrets/anthropic_api_key, and that
# secret is declared `lib.optionalAttrs (!isServer)` in system/sops.nix,
# so loading fulcrum on the `server` profile (tala) blows up at eval.
{
  imports = [
    # Pi models aggregator. Materializes ~/.pi/agent/models.json from
    # the merged services.piModels.providers attrset across all
    # contributing modules, with activation-time substitution for
    # secret base URLs. Universal: degrades to a no-op if no provider
    # contributes (e.g., a host without local-llm.nix and without the
    # litellm secrets provisioned).
    ./pi-models.nix

    # LiteLLM gateway provider (gpt-5.5, gpt-5.4, gemini-2.5-pro,
    # gemini-2.5-flash). Anthropic traffic deliberately stays off this
    # provider — see home/cli/pi.nix for the cycle composition
    # rationale. Degrades gracefully if /run/secrets/litellm_*
    # is missing.
    ./litellm.nix
  ]
  ++ lib.optionals (!isDarwinHost) [
    ./notes-sync.nix
    ./darkman.nix
  ]
  ++ lib.optionals (!isDarwinHost && !isServer) [
    ./fulcrum.nix
  ]
  ++ lib.optionals isDarwinHost [
    ./notes-sync-darwin.nix
  ]
  # local-llm.nix runs in two modes: server (workstation, llama.cpp
  # + ROCm + systemd user service) and client (prl-dev-vm / vmw-dev-vm,
  # baseUrl points at mac-work's LaunchAgent). The module itself
  # branches on `isWorkstation`; this gate just keeps the file off
  # hosts where neither mode applies (hp-laptop, tala).
  ++
    lib.optionals (hostName == "workstation" || hostName == "prl-dev-vm" || hostName == "vmw-dev-vm")
      [
        ./local-llm.nix
      ];
}
