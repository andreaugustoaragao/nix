{
  lib,
  owner,
  ...
}:

let
  # The on-disk store lives inside the notes vault so it travels with
  # the same backup story as the rest of fulcrum's state
  # (conversations.db, vault.db, sessions.json, etc.). Matches the
  # ${FULCRUM_VAULT_PATH}/.fulcrum/chroma path the upstream
  # docker-compose.yml uses on workstation, so the data layout is
  # identical across hosts.
  vaultDir = "/home/${owner.name}/projects/work/notes";
  chromaDataDir = "${vaultDir}/.fulcrum/chroma";
in

{
  # Run ChromaDB as a system-managed OCI container so the source-mode
  # Fulcrum service (home/services/fulcrum.nix) has a vector store to
  # talk to without anyone having to `docker compose up` by hand.
  # Workstation uses the upstream docker-compose.yml from the Fulcrum
  # repo (which brings up its own chroma alongside fulcrum), so this
  # module is intentionally gated to non-workstation hosts in
  # system/default.nix.
  #
  # The `:latest` tag mirrors the docker-compose; pin to a digest
  # (e.g. `chromadb/chroma@sha256:…`) if/when stricter reproducibility
  # is needed.
  virtualisation.oci-containers = {
    backend = "docker";
    containers.chroma = {
      image = "chromadb/chroma:latest";
      # Bind to localhost only — fulcrum reaches it via
      # CHROMA_BASE_URL=http://localhost:8000 (see fulcrum.nix). The
      # vector store should never be exposed off-host.
      ports = [ "127.0.0.1:8000:8000" ];
      volumes = [ "${chromaDataDir}:/chroma/chroma" ];
      environment = {
        IS_PERSISTENT = "TRUE";
        ANONYMIZED_TELEMETRY = "FALSE";
      };
      extraOptions = [ "--pull=missing" ];
    };
  };

  # Take docker-chroma.service OFF the boot transaction and bind it to
  # docker.service. The oci-containers module defaults to
  # WantedBy=multi-user.target, which at boot pulls chroma in *before*
  # the lazy-loaded docker daemon has had a chance to start — chroma
  # then burns through its 5-restart budget in under a second against a
  # dead socket and ends up permanently failed even after docker-lazy
  # later brings docker up.
  #
  # Hooking chroma to docker.service via Wants (= reverse of
  # `wantedBy = [ "docker.service" ]`) + PartOf means docker-lazy
  # starting docker.service automatically pulls chroma in, and chroma
  # cleanly follows docker through stop/restart cycles.
  #
  # RestartSec/StartLimit* absorb the inevitable race between
  # `dockerd` declaring ready and `docker run` actually succeeding.
  systemd.services.docker-chroma = {
    wantedBy = lib.mkForce [ "docker.service" ];
    partOf = [ "docker.service" ];
    serviceConfig = {
      RestartSec = lib.mkForce "5s";
    };
    unitConfig = {
      StartLimitBurst = 10;
      StartLimitIntervalSec = 120;
    };
  };

  # Ensure the bind-mount source exists before docker tries to use it
  # — without this the daemon creates it as root:root and the user
  # service later struggles to read it. The user-mode fulcrum service
  # has Restart=on-failure / RestartSec=5s and retries until chroma is
  # reachable on localhost:8000.
  systemd.tmpfiles.rules = [
    "d ${chromaDataDir} 0755 ${owner.name} users -"
  ];
}
