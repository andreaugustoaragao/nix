{
  description = "NixOS + nix-darwin configuration for a handful of personal hosts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Tracks nixpkgs-unstable for packages we want fresher than 25.11
    # (niri, zellij, pipewire). See `unstable-pkgs` consumers across
    # system/ and home/.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Pinned to the nixpkgs commit that bumped llama-cpp to b9190, the
    # first build to include MTP speculative decoding (PR ggml-org/llama.cpp#22673,
    # merged 2026-05-16). Drop this input once the nixpkgs-unstable channel
    # branch catches up past b9190 — at that point home/services/local-llm.nix
    # can switch back to using `unstable-pkgs.llama-cpp`.
    nixpkgs-llama.url = "github:NixOS/nixpkgs/dea49413a4cf3be31dc2afb836a90eeee4a5d3c2";
    # Pinned to nixos-25.05 solely to keep xdg-desktop-portal-gnome at
    # version 48.x. GNOME 49 added a hard requirement on
    # org.gnome.Mutter.ServiceChannel that the niri 26.04 in nixpkgs
    # doesn't yet expose, which sends the gnome portal into
    # "Non-compatible display server, exposing settings only" mode and
    # breaks ScreenCast/RemoteDesktop/Screenshot. Drop this input once
    # niri implements ServiceChannel.
    nixpkgs-gnome48.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code = {
      url = "github:sadjow/claude-code-nix";
      # Follow our nixpkgs so the lock doesn't carry a second, independently
      # versioned nixpkgs node. The overlay builds claude-code with
      # final.callPackage against the host's nixpkgs, and the package is a
      # sha256-pinned prebuilt fetch, so following changes no built byte.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CachyOS-tuned kernels for NixOS. Following our nixpkgs because
    # Lantian's binary cache only holds the build deps (LLVM, patched
    # source) — never the final kernel — so the cache-hash argument
    # for an unfollowed input doesn't apply. Following dedupes the
    # nixpkgs eval and keeps the kernel build aligned with the rest of
    # the system.
    cachyos-kernel = {
      url = "github:xddxdd/nix-cachyos-kernel/release";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nix-darwin,
      sops-nix,
      claude-code,

      ...
    }@inputs:
    let
      metadata = builtins.fromTOML (builtins.readFile ./machines.toml);

      # Get username for the platform
      getUserName = user: _host: user.name;

      # Darwin-platform predicate. macOS hosts live under
      # /Users/<name> and are built with darwinSystem; everywhere else
      # we assume Linux and use nixosSystem.
      isDarwinPlatform = platform: platform == "aarch64-darwin" || platform == "x86_64-darwin";

      homePrefixFor = platform: if isDarwinPlatform platform then "/Users" else "/home";

      # Set special args for each machine
      setSpecialArgs = host: {
        isWorkstation = host.profile == "workstation";
        isLaptop = host.profile == "laptop";
        isVm = host.profile == "vm";
        isServer = host.profile == "server";
        isDarwinHost = isDarwinPlatform host.platform;
        homePrefix = homePrefixFor host.platform;
        owner = metadata.user // {
          name = getUserName metadata.user host;
        };
        inherit (host) hostName stateVersion profile;
        # Optional wireless configuration
        wirelessInterface = host.wirelessInterface or null;
        # Optional bluetooth configuration
        bluetooth = host.bluetooth or false;
        # Optional lock screen configuration
        lockScreen = host.lockScreen or false;
        # Optional auto login configuration
        autoLogin = host.autoLogin or false;
        # Enable DankMaterialShell on this host. When true, conflicting
        # daemons (waybar, mako, hyprpaper, swayidle, swayosd,
        # hyprpolkitagent) are not autostarted so DMS owns the screen.
        useDms = host.useDms or false;
        # Per-host connector name map. The DMS config (and anywhere else
        # this flake references monitor outputs by name) thinks in
        # canonical dp1/dp2 slots — landscape primary on the right,
        # portrait secondary on the left on the workstation. The Wayland
        # connector names are platform-dependent: bare-metal DP outputs
        # come up as DP-1/DP-2, while Parallels (and VMware) virtio_gpu
        # exposes Virtual-1/Virtual-2. Map them here so screenPreferences,
        # monitorWallpapers, etc. resolve to the right strings without
        # per-host branches downstream. Override in machines.toml if a
        # host needs different names (e.g. eDP-1 on a laptop).
        displays =
          host.displays or (
            if host.profile == "vm" then
              {
                dp1 = "Virtual-1";
                dp2 = "Virtual-2";
              }
            else
              {
                dp1 = "DP-1";
                dp2 = "DP-2";
              }
          );
        # Logical dimensions of the dp2 slot (the portrait/secondary
        # screen) in scaled pixels. Used by DMS to anchor desktop widgets
        # — the cava visualizer in particular has its rectangle computed
        # from these so it lands flush with the bottom edge on whatever
        # connector the slot resolves to. Workstation = Dell S2725QS
        # rotated 270° at scale 1.5 (3840x2160 → 1440x2560 portrait); VM
        # = Parallels Virtual-2 retina mode at scale 2.0 (3384x6016 →
        # 1692x3008). Override in machines.toml if the Parallels window
        # size or workstation monitor changes.
        dp2Dimensions =
          host.dp2Dimensions or (
            if host.profile == "vm" then
              {
                width = 1692;
                height = 3008;
              }
            else
              {
                width = 1440;
                height = 2560;
              }
          );
        # Optional homebrew casks / brews for Darwin hosts. Ignored on
        # Linux where the darwin/homebrew.nix module isn't imported.
        homebrewCasks = host.homebrewCasks or [ ];
        homebrewBrews = host.homebrewBrews or [ ];
        inherit inputs;
      };

      # Set Home Manager template (works for both NixOS and nix-darwin
      # since both expose `home-manager = { useUserPackages, useGlobalPkgs,
      # ... }` once the corresponding HM module is imported).
      setHomeManagerTemplate = host: {
        home-manager = {
          useUserPackages = true;
          useGlobalPkgs = true;
          extraSpecialArgs = setSpecialArgs host;
          users.${getUserName metadata.user host} = import ./home;
          backupFileExtension = "hm-backup";
        };
      };

      # Partition machines.toml entries by platform.
      machinesBy = pred: nixpkgs.lib.filterAttrs (_: host: pred host.platform) metadata.machines;
      linuxMachines = machinesBy (p: !isDarwinPlatform p);
      darwinMachines = machinesBy isDarwinPlatform;

      # Systems we expose `nix run .#<app>` on. Anything that can run
      # `nix run` from inside the flake checkout. Keep this list aligned
      # with the platforms in machines.toml.
      appSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachAppSystem = nixpkgs.lib.genAttrs appSystems;
    in
    {
      # NixOS configurations for Linux machines
      nixosConfigurations = builtins.mapAttrs (
        machineName: host:
        nixpkgs.lib.nixosSystem {
          specialArgs = setSpecialArgs host;
          modules = [
            { nixpkgs.hostPlatform = host.platform; }
            {
              nixpkgs.overlays = [
                claude-code.overlays.default
                # See nixpkgs-gnome48 input above for the why.
                (_final: _prev: {
                  inherit (inputs.nixpkgs-gnome48.legacyPackages.${host.platform}) xdg-desktop-portal-gnome;
                })
              ];
            }
            # Hardware configuration
            (./hardware + "/${machineName}" + /hardware-configuration.nix)
            # System configuration
            ./system
            # Prebuilt nix-index database for command-not-found lookup.
            inputs.nix-index-database.nixosModules.nix-index
            # Secrets management
            sops-nix.nixosModules.sops
            # Home Manager configuration
            home-manager.nixosModules.home-manager
            (setHomeManagerTemplate host)
          ];
        }
      ) linuxMachines;

      # nix-darwin configurations for macOS machines. The Darwin module
      # set (./darwin) is intentionally small: no boot/audio/wireless/
      # display-manager, and the home-manager module set under ./home
      # gates its Linux-only pieces on pkgs.stdenv.isLinux.
      darwinConfigurations =
        let
          base = builtins.mapAttrs (
            _machineName: host:
            nix-darwin.lib.darwinSystem {
              specialArgs = setSpecialArgs host;
              modules = [
                { nixpkgs.hostPlatform = host.platform; }
                {
                  nixpkgs.overlays = [
                    claude-code.overlays.default
                  ];
                }
                ./darwin
                inputs.nix-index-database.darwinModules.nix-index
                sops-nix.darwinModules.sops
                home-manager.darwinModules.home-manager
                (setHomeManagerTemplate host)
              ];
            }
          ) darwinMachines;
        in
        # Convenience alias: darwin-rebuild with bare `--flake .` looks
        # up `darwinConfigurations.<hostname>`, and the macOS HostName
        # is pinned to IT's asset tag (G7CH2W2XYR), not the flake key
        # (mac-work). Expose both names so either invocation works.
        base // { G7CH2W2XYR = base.mac-work; };

      # Cross-host SSH bootstrap apps. Exposed on every system in appSystems
      # so the same `nix run .#peers-bootstrap` works from any host in
      # the set. The scripts are deliberately self-contained shell
      # applications — they only need git, openssh, and coreutils.
      apps = forEachAppSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Generates ~/.ssh/id_ed25519_peers on the current host, drops
          # the pubkey into the flake at secrets/ssh_pubkeys/, scans the
          # host keys of well-known peers into secrets/ssh_host_keys/,
          # then commits and pushes. Idempotent: rerunning is a no-op if
          # nothing changed.
          peersBootstrap = pkgs.writeShellApplication {
            name = "peers-bootstrap";
            runtimeInputs = with pkgs; [
              openssh
              git
              coreutils
              gnused
              gawk
            ];
            text = ''
              set -euo pipefail

              log() { printf '[peers-bootstrap] %s\n' "$*" >&2; }

              FLAKE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
              if [ -z "$FLAKE_DIR" ]; then
                log "error: not inside a git checkout. cd to the flake root first."
                exit 1
              fi

              raw_host="$(uname -n)"
              HOST="''${raw_host%%.*}"

              KEY="$HOME/.ssh/id_ed25519_peers"
              PUB="$KEY.pub"

              mkdir -p "$HOME/.ssh"
              chmod 700 "$HOME/.ssh"

              if [ ! -f "$KEY" ]; then
                log "generating ed25519 keypair at $KEY"
                ssh-keygen -t ed25519 -f "$KEY" -N "" -C "aragao@''${HOST}-peers"
              else
                log "keypair already exists at $KEY"
              fi

              DEST_PUB_DIR="$FLAKE_DIR/secrets/ssh_pubkeys"
              DEST_PUB="$DEST_PUB_DIR/''${HOST}_peers.pub"
              mkdir -p "$DEST_PUB_DIR"

              if ! cmp -s "$PUB" "$DEST_PUB" 2>/dev/null; then
                log "registering pubkey at secrets/ssh_pubkeys/''${HOST}_peers.pub"
                cp "$PUB" "$DEST_PUB"
              else
                log "pubkey already registered"
              fi

              # Pin well-known peers' host keys so StrictHostKeyChecking=yes
              # can be enforced without a TOFU first-connect window. Add
              # new peers to this list as they come online.
              DEST_HOST_DIR="$FLAKE_DIR/secrets/ssh_host_keys"
              mkdir -p "$DEST_HOST_DIR"

              # Each entry is "<hostname>=<address>". The hostname is what
              # we save the .pub under (and what ssh-config.nix prepends to
              # the known_hosts line). The address is what ssh-keyscan
              # actually connects to — using IPs sidesteps the Bonjour
              # dependency the rest of this flake used to lean on.
              KEYSCAN_TARGETS=( "prl-dev-vm=10.211.55.4" "vmw-dev-vm=192.168.150.5" )
              for entry in "''${KEYSCAN_TARGETS[@]}"; do
                target_short="''${entry%%=*}"
                target="''${entry#*=}"
                host_file="$DEST_HOST_DIR/''${target_short}.pub"
                log "ssh-keyscan -t ed25519 $target  ($target_short)"
                if scan="$(ssh-keyscan -t ed25519 -T 5 "$target" 2>/dev/null || true)" && [ -n "$scan" ]; then
                  # ssh-keyscan emits BOTH a `# <host>:<port> SSH-2.0-...`
                  # banner comment and one or more key lines. Filter
                  # explicitly to lines whose second column begins with
                  # `ssh-` — the comment line has `# <host>:port ...`
                  # which doesn't match. Strip the leading hostname column
                  # so the file matches the bare-key format that the
                  # known_hosts assembler in home/cli/ssh-config.nix
                  # prepends `<host>,<host>.local ` to.
                  key_line="$(echo "$scan" | awk '$2 ~ /^ssh-/ { $1=""; sub(/^ /,""); print; exit }')"
                  if [ -n "$key_line" ] && [[ "$key_line" =~ ^ssh- ]]; then
                    echo "$key_line" > "$host_file"
                    log "  wrote secrets/ssh_host_keys/''${target_short}.pub"
                  else
                    log "  warning: keyscan returned no usable key (got: $scan)"
                  fi
                else
                  log "  warning: ssh-keyscan failed for $target (host unreachable?)"
                fi
              done

              cd "$FLAKE_DIR"
              git add secrets/ssh_pubkeys secrets/ssh_host_keys

              if git diff --cached --quiet; then
                log "no flake changes to commit"
              else
                log "committing"
                git commit -m "peers: bootstrap ''${HOST} pubkey + scanned hostkeys"
                log "pushing to origin/main"
                git push origin HEAD:main
              fi

              # Best-effort: load the key into the running agent so this
              # session can SSH immediately, without re-login / launchctl
              # kickstart. Harmless if no agent is running.
              if [ -n "''${SSH_AUTH_SOCK:-}" ]; then
                # Use a real if/else rather than the `A && B || C`
                # shorthand. writeShellApplication runs shellcheck on
                # the script body and flags the shorthand under SC2015,
                # because C runs when A is true but B fails — which
                # would silently misreport the agent state here.
                if ssh-add "$KEY" </dev/null 2>/dev/null; then
                  log "loaded key into running ssh-agent"
                else
                  log "note: ssh-add to agent failed (re-login to pick up)"
                fi
              fi

              cat >&2 <<EOF

              peers-bootstrap complete.

              Next steps:
                1. On the target host (e.g. prl-dev-vm):
                     cd ~/projects/personal/nix
                     git pull
                     sudo nixos-rebuild switch --flake .#prl-dev-vm

                2. Back here, test:
                     ssh prl-dev-vm

                3. Once SSH works, fetch the kubeconfig:
                     nix run .#peers-kube-fetch -- prl-dev-vm
              EOF
            '';
          };

          # Pulls /etc/rancher/k3s/k3s.yaml from a peer host over SSH,
          # rewrites the loopback server URL to the host's .local mDNS
          # name, renames k3s's generic `default` cluster/context/user
          # to the host name (so future multi-cluster merges don't
          # collide), and drops it at ~/.kube/config-<host> with mode
          # 0600. Also symlinks ~/.kube/config to point at the most
          # recently fetched cluster, making it kubectl's default with
          # no KUBECONFIG env var needed. Idempotent: re-run after k3s
          # reinstalls to refresh the cert.
          peersKubeFetch = pkgs.writeShellApplication {
            name = "peers-kube-fetch";
            runtimeInputs = with pkgs; [
              openssh
              coreutils
              gnused
            ];
            text = ''
              set -euo pipefail

              log() { printf '[peers-kube-fetch] %s\n' "$*" >&2; }

              host="''${1:-prl-dev-vm}"
              kube_host="$host.local"

              mkdir -p "$HOME/.kube"
              dest="$HOME/.kube/config-$host"
              default_link="$HOME/.kube/config"

              log "fetching kubeconfig from $host"
              raw="$(ssh -o BatchMode=yes "$host" 'cat /etc/rancher/k3s/k3s.yaml')"

              log "rewriting server URL and renaming default -> $host"
              # Anchor each substitution to the YAML's structural
              # indentation so the literal word "default" appearing
              # inside a cert or comment can't accidentally match.
              rewritten="$(printf '%s' "$raw" | sed \
                -e "s|server: https://127.0.0.1:6443|server: https://$kube_host:6443|" \
                -e "s/^  name: default\$/  name: $host/" \
                -e "s/^    cluster: default\$/    cluster: $host/" \
                -e "s/^    user: default\$/    user: $host/" \
                -e "s/^current-context: default\$/current-context: $host/" \
                -e "s/^- name: default\$/- name: $host/")"

              umask 077
              printf '%s\n' "$rewritten" > "$dest"
              log "wrote $dest (mode 0600)"

              # Make this the kubectl default. Honor any existing
              # ~/.kube/config: if it's a regular file (manually managed),
              # back it up before replacing with our symlink. If it's
              # already a symlink to a different target, log and replace.
              # If it already points at our file, ln -sf is idempotent.
              if [ -e "$default_link" ] && [ ! -L "$default_link" ]; then
                backup="$default_link.bak-$(date +%Y%m%d-%H%M%S)"
                log "backing up existing $default_link -> $backup"
                mv "$default_link" "$backup"
              elif [ -L "$default_link" ]; then
                current_target="$(readlink "$default_link")"
                if [ "$current_target" != "$dest" ]; then
                  log "replacing default symlink (was: $current_target)"
                fi
              fi
              ln -sf "$dest" "$default_link"
              # SC2088: `~` inside double quotes is literal text, not
              # $HOME, so use $HOME explicitly. Bonus: the printed path
              # is the real one users can copy into other commands.
              log "$HOME/.kube/config -> $HOME/.kube/config-$host (current default)"
              log ""
              log "test with:"
              log "  kubectl get nodes"
              log "  kubectl config get-contexts    # should show '$host' marked *"
            '';
          };

          # Sets up a Docker context that targets a peer host's dockerd
          # over SSH (`docker host=ssh://<host>`), then marks it as the
          # active default. Mirrors the kubectl flow but uses Docker's
          # native context mechanism instead of a config file — no env
          # var, no daemon TCP socket, no TLS certs.
          #
          # Prerequisites (already met for prl-dev-vm via system/users.nix
          # + ssh.nix + virtualization.nix):
          #   - SSH works from this host to <host> as the local user
          #   - That user is in the `docker` group on <host>
          #   - dockerd is running on <host>
          #
          # Caveat: bind mounts (`docker run -v <path>:<dest>`) resolve
          # <path> on the SERVER (<host>), not on the client. Same
          # caveat that applies to any remote-Docker setup.
          peersDockerSetup = pkgs.writeShellApplication {
            name = "peers-docker-setup";
            runtimeInputs = with pkgs; [
              openssh
              docker-client
              coreutils
            ];
            text = ''
              set -euo pipefail

              log() { printf '[peers-docker-setup] %s\n' "$*" >&2; }

              host="''${1:-prl-dev-vm}"
              endpoint="ssh://$host"

              # Smoke-test the SSH+docker chain before mutating local
              # docker state. Fast failure with a clear message beats
              # creating a context that then errors at every `docker ps`.
              log "smoke-testing ssh $host docker version"
              if ! ssh -o BatchMode=yes "$host" 'docker version --format "{{.Server.Version}}"' >/dev/null 2>&1; then
                log "  FAILED. Check that:"
                log "    - ssh $host    works without a prompt"
                log "    - the remote user is in the docker group"
                log "    - dockerd is running on $host"
                exit 1
              fi
              log "  ok"

              # `docker context create` errors if the context exists;
              # `docker context update` errors if it doesn't. Pick the
              # right one so re-runs are idempotent.
              if docker context inspect "$host" >/dev/null 2>&1; then
                log "updating existing context: $host -> $endpoint"
                docker context update "$host" --docker "host=$endpoint" >/dev/null
              else
                log "creating context: $host -> $endpoint"
                docker context create "$host" --docker "host=$endpoint" >/dev/null
              fi

              log "setting $host as the active default context"
              docker context use "$host" >/dev/null

              log "verifying via local docker CLI"
              if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
                remote_version="$(docker version --format '{{.Server.Version}}')"
                log "  ok — remote daemon version: $remote_version"
              else
                log "  warning: docker version against $host failed unexpectedly"
              fi

              log ""
              log "docker is now talking to $host. test with:"
              log "  docker ps"
              log "  docker context ls           # shows '$host' marked *"
              log ""
              log "to revert to local Docker (e.g. OrbStack on mac-work):"
              log "  docker context use default"
            '';
          };
        in
        {
          peers-bootstrap = {
            type = "app";
            program = "${peersBootstrap}/bin/peers-bootstrap";
            meta.description = "Generate the peer identity key, exchange host keys, and authorise this host on every other machine in the flake.";
          };
          peers-kube-fetch = {
            type = "app";
            program = "${peersKubeFetch}/bin/peers-kube-fetch";
            meta.description = "Fetch a remote host's k3s/kubectl kubeconfig over SSH and merge it into ~/.kube/config.";
          };
          peers-docker-setup = {
            type = "app";
            program = "${peersDockerSetup}/bin/peers-docker-setup";
            meta.description = "Configure a Docker context that talks to a remote host's Docker daemon over the peer SSH link.";
          };
        }
      );

      # `nix fmt` runs the RFC 166 formatter (nixfmt-rfc-style), matching the
      # CLAUDE.md quality gate. Exposed for every system in appSystems.
      formatter = forEachAppSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
