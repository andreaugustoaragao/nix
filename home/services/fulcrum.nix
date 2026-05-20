{
  config,
  osConfig,
  pkgs,
  lib,
  hostName,
  isWorkstation,
  ...
}:

let
  # Source checkout — service is a no-op on machines that don't have it
  # (guarded via ConditionPathExists below). Update flow:
  #
  #   cd ~/projects/work/fulcrum && git pull
  #   systemctl --user restart fulcrum
  #
  projectRoot = "${config.home.homeDirectory}/projects/work/fulcrum";

  # Runtime library path for native modules (onnxruntime / sharp in
  # @huggingface/transformers). `libstdc++` is the one that actually
  # broke when we first tried to run under a bare PATH; keep the list
  # small to avoid pulling the world, but expand if something new
  # complains about a missing .so at boot.
  fulcrumLibs = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib # libstdc++.so.6
    pkgs.zlib # libz.so.1
    pkgs.glib # libglib-2.0.so.0 (occasionally pulled by image libs)
  ];

  # Tools the service shell needs — bun to run, git so the process can
  # report its own rev via /api/version, coreutils/which for script
  # compatibility in case bun shells out. openssl is used by the
  # ExecStart wrapper to lazily provision a self-signed localhost cert
  # the first time the service starts, mirroring the
  # mkcert-generated cert workstation's docker-compose stack mounts in.
  binPath = lib.makeBinPath [
    pkgs.bun
    pkgs.git
    pkgs.coreutils
    pkgs.which
    pkgs.openssl
  ];

  # Per-user cert/key for fulcrum's HTTPS listener — kept outside the
  # source checkout so a fresh clone doesn't accidentally pick them up,
  # and outside the vault so they don't get auto-synced to GitHub.
  tlsDir = "${config.xdg.dataHome}/fulcrum/certs";
  tlsCert = "${tlsDir}/localhost.pem";
  tlsKey = "${tlsDir}/localhost-key.pem";
in

{
  systemd.user.services.fulcrum = {
    Unit = {
      Description = "Fulcrum — executive operational intelligence (source)";
      Documentation = [ "file://${projectRoot}/CLAUDE.md" ];
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # No-op on machines without the project checked out.
      ConditionPathExists = projectRoot;
    };

    Service = {
      Type = "exec";
      WorkingDirectory = projectRoot;
      Environment = [
        "PATH=${binPath}:/run/current-system/sw/bin"
        "LD_LIBRARY_PATH=${fulcrumLibs}"
        "NODE_OPTIONS=--max-old-space-size=4096"
        "FULCRUM_PORT=3100"
        # Bind to all interfaces so peers on the LAN (e.g., the
        # Parallels host mac-work reaching this VM at
        # prl-dev-vm.local:3100) can hit it. The firewall opens 3100
        # only on hosts that actually run fulcrum from source (see
        # system/networking.nix).
        "FULCRUM_HOST=0.0.0.0"
        # Vector store — declared as a system OCI container in
        # system/chroma.nix and bound to localhost:8000. Without this
        # override Fulcrum falls back to `http://chroma:8000`, which only
        # resolves inside docker-compose's network.
        "CHROMA_BASE_URL=http://localhost:8000"
      ]
      # Voice-message transcription. Non-workstation hosts have no
      # local whisper binary on PATH (the Dockerfile bakes one in,
      # but source-mode fulcrum doesn't), so the upstream adapter's
      # CLI shellout would fail. Point it at mac-work's whisper-server
      # LaunchAgent (darwin/services/whisper-server.nix), reached over
      # the Parallels shared network via mDNS. Adapter checks for this
      # env and switches to HTTP mode — see whisper-adapter.ts.
      ++ lib.optionals (!isWorkstation) [
        "WHISPER_SERVER_URL=http://mac-work.local:8081/v1/audio/transcriptions"
      ]
      ++ [
        # Reuse the vault's .fulcrum/ as the on-disk data dir so config.json,
        # sessions.json, conversations.db, vault.db, etc. travel with the
        # notes repo across machines — instead of fulcrum spinning up an
        # empty .agents/ next to the source checkout on each new host.
        "FULCRUM_DATA_DIR=${config.home.homeDirectory}/projects/work/notes/.fulcrum"
        # Matrix bot — reuses the @maui-alerts identity that already exists
        # on matrix.faragao.net (see system/matrix-alert.nix). The access
        # token lives in sops as matrix/bot_token; we point Fulcrum at the
        # file path via the _FILE env-var convention so the cleartext never
        # ends up in /proc/<pid>/environ.
        #
        # device_id was minted at the same time as the token; the server
        # returns it via /_matrix/client/v3/account/whoami. Fulcrum needs
        # it to call session.startClient — if we pass a different value the
        # homeserver returns a fresh device on each restart which fragments
        # E2E keys. The alert room is unencrypted so this currently doesn't
        # bite, but we set the real device_id anyway for future-proofing.
        "MATRIX_HOMESERVER_URL=https://matrix.faragao.net"
        "MATRIX_USER_ID=@maui-alerts:matrix.faragao.net"
        "MATRIX_DEVICE_ID=AeSV8hGVoC"
        "MATRIX_ACCESS_TOKEN_FILE=${osConfig.sops.secrets."matrix/bot_token".path}"
      ];
      # ANTHROPIC_API_KEY comes from the sops-managed system secret
      # (see system/sops.nix → anthropic_api_key) so it's the same key
      # the fish shell and Zed wrapper use. Fulcrum has no built-in
      # ANTHROPIC_API_KEY_FILE support, so a thin wrapper reads the
      # file and exports the value before exec'ing bun. The vault's
      # ${projectRoot}/.env (symlinked to ~/projects/work/notes/.fulcrum/.env)
      # is still auto-loaded by bun for the other secrets (TELEGRAM,
      # ELEVENLABS, MPC, …); bun does not override env vars already set
      # by the wrapper, so the sops key wins.
      ExecStart = pkgs.writeShellScript "fulcrum-start" ''
        set -eu
        secret=${osConfig.sops.secrets.anthropic_api_key.path}
        if [ ! -r "$secret" ]; then
          echo "Fatal: $secret not readable" >&2
          exit 1
        fi
        raw=$(cat "$secret")
        # Accept either bare key bytes or `ANTHROPIC_API_KEY=...` shell form,
        # mirroring how fish/zed strip the prefix.
        export ANTHROPIC_API_KEY="''${raw#ANTHROPIC_API_KEY=}"

        # Lazily provision a self-signed cert for the HTTPS listener.
        # Fulcrum's startup picks up the cert/key via
        # FULCRUM_TLS_CERT/_KEY (see startup.ts:244), so the web-app
        # PWA's https://localhost:3100 works the same way it does on
        # workstation (which gets its cert from mkcert via the
        # upstream docker-compose stack). Self-healing: regenerate
        # whenever the cert is missing OR its SAN list doesn't yet
        # include ${hostName}.local, so cert content stays in sync
        # with nix-side SAN changes across rebuilds.
        regen_cert=0
        if [ ! -f ${tlsCert} ] || [ ! -f ${tlsKey} ]; then
          regen_cert=1
        elif ! openssl x509 -in ${tlsCert} -noout -ext subjectAltName 2>/dev/null \
             | grep -q "DNS:${hostName}.local"; then
          regen_cert=1
        fi
        if [ "$regen_cert" = "1" ]; then
          mkdir -p ${tlsDir}
          openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout ${tlsKey} \
            -out ${tlsCert} \
            -days 3650 \
            -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost,DNS:fulcrum.local,DNS:${hostName}.local,IP:127.0.0.1" \
            >/dev/null 2>&1
          chmod 0600 ${tlsKey}
        fi
        export FULCRUM_TLS_CERT=${tlsCert}
        export FULCRUM_TLS_KEY=${tlsKey}

        exec ${pkgs.bun}/bin/bun run start
      '';

      Restart = "on-failure";
      RestartSec = "5s";
      # Bun handles SIGTERM gracefully (drains SSE streams); give it room.
      KillMode = "mixed";
      TimeoutStopSec = "15s";

      # Soft resource ceilings to keep a runaway sub-agent from eating the
      # machine. Bump if you hit them in practice.
      MemoryHigh = "3G";
      MemoryMax = "5G";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
