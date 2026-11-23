{
  config,
  osConfig,
  pkgs,
  unstable-pkgs,
  lib,
  hostName,
  isWorkstation,
  ...
}:

let
  sourceRoot = "${config.home.homeDirectory}/projects/work/fulcrum";
  vaultV2 = config.my.vaultV2 or { enable = false; };
  vaultV2Fulcrum = vaultV2.fulcrumRelease or null;
  packagedRelease = if vaultV2.enable && vaultV2Fulcrum != null then vaultV2Fulcrum else null;
  projectRoot =
    if packagedRelease != null then "${packagedRelease}/share/vault-services" else sourceRoot;
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
  runtimeTools = pkgs.callPackage ./fulcrum-runtime.nix { inherit unstable-pkgs; };
  runtimeBinPath = lib.makeBinPath [
    runtimeTools.npm
    runtimeTools.azure-cli
    runtimeTools.ffmpeg
  ];
  serviceBinPath = lib.makeBinPath [
    pkgs.bun
    pkgs.git
    pkgs.coreutils
    pkgs.which
    pkgs.openssl
    (pkgs.callPackage ../../pkgs/dev-browser.nix { })
  ];
  binPath = lib.optionalString (hostName == "prl-dev-vm") "${runtimeBinPath}:" + serviceBinPath;
  effectiveRuntimePath = lib.concatStringsSep ":" (
    lib.optionals (packagedRelease != null) [
      "${packagedRelease}/bin"
      "${projectRoot}/node_modules/.bin"
    ]
    ++ lib.optionals (vaultV2.enable && vaultV2.package != packagedRelease) [
      "${vaultV2.package}/bin"
    ]
    ++ [
      runtimeBinPath
      "${pkgs.nodejs_26}/bin"
      serviceBinPath
      "/etc/profiles/per-user/${config.home.username}/bin"
      "/run/current-system/sw/bin"
    ]
  );

  # Per-user cert/key for fulcrum's HTTPS listener — kept outside the
  # source checkout so a fresh clone doesn't accidentally pick them up,
  # and outside the vault so they don't get auto-synced to GitHub.
  tlsDir = "${config.xdg.dataHome}/fulcrum/certs";
  tlsCert = "${tlsDir}/localhost.pem";
  tlsKey = "${tlsDir}/localhost-key.pem";
  localTls = config.my.fulcrum.localTls;
  runtimeTlsCert = if localTls.enable then localTls.serverCertificate else tlsCert;
  runtimeTlsKey = if localTls.enable then localTls.serverKey else tlsKey;
  browserNickname =
    if localTls.enable then
      "fulcrum-local-https-prl-dev-vm-ca-v1"
    else
      "fulcrum-local-https-prl-dev-vm";
  browserFingerprint =
    if localTls.enable then
      localTls.serverSha256
    else
      "8FD6E07212A5002ECF9973027FBB5678181F81216343EA6D9727E8E6C82BE399";
  localTlsDesktop = pkgs.callPackage ../../pkgs/fulcrum-desktop-local-tls.nix {
    inherit (localTls) caCertificate caSha256 desktopPackage;
    systemCaBundle = osConfig.environment.etc."ssl/certs/ca-certificates.crt".source;
  };

  # This host's existing certificate is CA-capable. NSS P,, trusts only its
  # exact DER identity for TLS; C,, or the system CA bundle would also trust
  # certificates signed by its key. Pin the public certificate, never the key.
  browserTrust = pkgs.writeShellApplication {
    name = "fulcrum-browser-trust";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.nssTools
      pkgs.openssl
    ];
    text = builtins.readFile ./fulcrum-browser-trust.sh;
  };
in

{
  imports = [ ./fulcrum-local-tls-options.nix ];
  assertions = [
    {
      assertion =
        !localTls.enable
        || (
          hostName == "prl-dev-vm"
          && localTls.caCertificate != null
          && localTls.caSha256 != null
          && localTls.serverSha256 != null
          && localTls.desktopPackage != null
        );
      message = "Fulcrum local TLS migration requires prl-dev-vm, an approved public CA, both reviewed fingerprints and a pinned desktop package. Stage and verify before enabling.";
    }
  ];
  home.packages = lib.optionals localTls.enable [ localTlsDesktop ];

  home.activation.fulcrumBrowserTrust = lib.mkIf (hostName == "prl-dev-vm") (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # Chromium 154 uses the legacy NSS directory when present, otherwise XDG.
      fulcrum_nss_database=${lib.escapeShellArg "${config.xdg.dataHome}/pki/nssdb"}
      if [ -d ${lib.escapeShellArg "${config.home.homeDirectory}/.pki/nssdb"} ]; then
        fulcrum_nss_database=${lib.escapeShellArg "${config.home.homeDirectory}/.pki/nssdb"}
      fi
      if [ -r ${lib.escapeShellArg runtimeTlsCert} ]; then
        run ${browserTrust}/bin/fulcrum-browser-trust \
          ${lib.escapeShellArg runtimeTlsCert} "$fulcrum_nss_database" \
          ${lib.escapeShellArg browserNickname} \
          ${lib.escapeShellArg browserFingerprint}
      fi
    ''
  );

  # The existing runtime.conf selects the managed Node/Bun launcher and PATH.
  # Sort after it and override only PATH; preserve its ExecStart and other settings.
  xdg.configFile."systemd/user/fulcrum.service.d/zz-fulcrum-runtime-tools.conf" =
    lib.mkIf (hostName == "prl-dev-vm")
      {
        text = ''
          [Service]
          Environment="PATH=${effectiveRuntimePath}"
        '';
      };

  systemd.user.services.fulcrum = {
    Unit = {
      Description = "Fulcrum — executive operational intelligence (${
        if packagedRelease != null then "Nix release" else "source"
      })";
      Documentation = [ "file://${projectRoot}/docs/README.md" ];
      After = [
        "network-online.target"
      ]
      ++ lib.optionals vaultV2.enable [
        "shared-vault-v2.service"
        "ai-task-scheduler.service"
      ];
      Wants = [
        "network-online.target"
      ]
      ++ lib.optionals vaultV2.enable [
        "shared-vault-v2.service"
        "ai-task-scheduler.service"
      ];
      ConditionPathExists = lib.mkIf (packagedRelease == null) projectRoot;
    };

    Service = {
      Type = "exec";
      RuntimeDirectory = if packagedRelease != null then "fulcrum-v2" else lib.mkIf (hostName == "prl-dev-vm") "fulcrum-desktop";
      RuntimeDirectoryMode = if packagedRelease != null then "0700" else lib.mkIf (hostName == "prl-dev-vm") "0700";
      WorkingDirectory = projectRoot;
      Environment = [
        "PATH=${binPath}:/run/current-system/sw/bin"
        "LD_LIBRARY_PATH=${fulcrumLibs}"
        "NODE_OPTIONS=--max-old-space-size=4096"
        "FULCRUM_PORT=3100"
        "FULCRUM_HOST=0.0.0.0"
      ]
      ++ lib.optionals (packagedRelease != null) [
        "FULCRUM_V2_STATE_DIR=${config.xdg.dataHome}/fulcrum-v2/app"
        "FULCRUM_VAULT_DIR=${config.home.homeDirectory}/projects/work/notes"
        "FULCRUM_VAULT_V2_SOCKET=%t/shared-vault-v2/api.sock"
        "FULCRUM_SCHEDULER_SOCKET=%t/ai-task-scheduler/api.sock"
        "FULCRUM_CALLBACK_SOCKET=%t/fulcrum-v2/callback.sock"
        "FULCRUM_WEB_DIST_DIR=${projectRoot}/v2/web/dist"
        "FULCRUM_PACKAGE_ROOT=${projectRoot}"
      ]
      ++ lib.optionals (packagedRelease == null && vaultV2.enable) [
        "FULCRUM_VAULT_V2_SOCKET=%t/shared-vault-v2/api.sock"
        "FULCRUM_SCHEDULER_SOCKET=%t/ai-task-scheduler/api.sock"
      ]
      ++ lib.optionals (!vaultV2.enable) [
        "CHROMA_BASE_URL=http://localhost:8000"
      ]
      ++ lib.optionals (packagedRelease == null) [
        "FULCRUM_DATA_DIR=${config.home.homeDirectory}/projects/work/notes/.fulcrum"
      ];
      # OpenAI-compatible inference is routed through the same corporate
      # LiteLLM gateway and bearer token that Codex uses. Both values stay
      # in sops-managed runtime files; the wrapper exports the conventional
      # OpenAI variables only in the service process, so neither secret nor
      # the employer-specific gateway hostname enters the Nix store.
      # The vault's .fulcrum/.env is loaded explicitly for the shared
      # release; source mode keeps Bun's existing .env discovery (TELEGRAM,
      # ELEVENLABS, MPC, …); bun does not override env vars already set
      # by the wrapper, so the sops key wins.
      ExecStart = pkgs.writeShellScript "fulcrum-start" ''
        set -eu
        api_key_secret=${osConfig.sops.secrets.litellm_api_key.path}
        base_url_secret=${osConfig.sops.secrets.litellm_base_url.path}
        if [ ! -r "$api_key_secret" ]; then
          echo "Fatal: $api_key_secret not readable" >&2
          exit 1
        fi
        if [ ! -r "$base_url_secret" ]; then
          echo "Fatal: $base_url_secret not readable" >&2
          exit 1
        fi
        api_key=$(cat "$api_key_secret")
        base_url=$(cat "$base_url_secret")
        if [ -z "$api_key" ] || [ "$api_key" = "placeholder" ]; then
          echo "Fatal: LiteLLM API key is empty or placeholder-valued" >&2
          exit 1
        fi
        if [ -z "$base_url" ] || [ "$base_url" = "placeholder" ]; then
          echo "Fatal: LiteLLM base URL is empty or placeholder-valued" >&2
          exit 1
        fi
        export LITELLM_API_KEY="$api_key"
        export LITELLM_BASE_URL="$base_url"
        export OPENAI_API_KEY="$api_key"
        export OPENAI_BASE_URL="$base_url"
        unset api_key base_url

        ${
          if localTls.enable then
            ''
              # Explicitly staged CA:false leaf. Never generate a replacement or
              # fall back to the former self-signed certificate in migration mode.
              ${localTlsDesktop.preflight}/bin/fulcrum-local-tls-preflight server \
                ${lib.escapeShellArg "${localTlsDesktop.publicCa}"} \
                ${lib.escapeShellArg localTls.caSha256} \
                ${lib.escapeShellArg localTls.serverCertificate} \
                ${lib.escapeShellArg localTls.serverSha256} \
                ${lib.escapeShellArg localTls.serverKey} \
                ${lib.escapeShellArg hostName}
            ''
          else
            ''
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
            ''
        }
        export FULCRUM_TLS_CERT=${lib.escapeShellArg runtimeTlsCert}
        export FULCRUM_TLS_KEY=${lib.escapeShellArg runtimeTlsKey}

        ${
          if packagedRelease != null then
            ''
              v2_env=${lib.escapeShellArg "${config.xdg.dataHome}/fulcrum-v2/app/.env"}
              if [ -f "$v2_env" ]; then
                exec ${packagedRelease}/bin/bun --env-file="$v2_env" ${lib.escapeShellArg "${projectRoot}/v2/server/src/main.ts"}
              else
                exec ${packagedRelease}/bin/bun --no-env-file ${lib.escapeShellArg "${projectRoot}/v2/server/src/main.ts"}
              fi
            ''
          else
            ''
              exec ${pkgs.bun}/bin/bun run start
            ''
        }
      '';
      Restart = "on-failure";
      RestartSec = "5s";
      # Bun handles SIGTERM gracefully (drains SSE streams); give it room.
      KillMode = "mixed";
      TimeoutStopSec = if packagedRelease != null then "180s" else "15s";

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
