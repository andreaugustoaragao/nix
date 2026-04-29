{ config, pkgs, lib, inputs, ... }:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  
  # Script to install qwen-code via npm
  install-qwen-code = pkgs.writeShellScriptBin "install-qwen-code" ''
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    mkdir -p "$NPM_CONFIG_PREFIX/bin"
    export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
    ${pkgs.nodejs_22}/bin/npm install -g @qwen-code/qwen-code
    echo "qwen-code installed successfully!"
    echo "Make sure $HOME/.npm-global/bin is in your PATH"
  '';

  # Script to install Google Gemini CLI via npm
  install-gemini-cli = pkgs.writeShellScriptBin "install-gemini-cli" ''
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    mkdir -p "$NPM_CONFIG_PREFIX/bin"
    export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
    ${pkgs.nodejs_22}/bin/npm install -g @google/gemini-cli
    echo "Gemini CLI installed successfully!"
    echo "Run 'gemini' to start using it"
  '';

  # Script to install goplay (Go Playground client) via go install
  install-goplay = pkgs.writeShellScriptBin "install-goplay" ''
    export GOPATH="''${GOPATH:-$HOME/go}"
    export GOBIN="''${GOBIN:-$GOPATH/bin}"
    ${unstable-pkgs.go}/bin/go install github.com/haya14busa/goplay/cmd/goplay@v1.0.0
    echo "goplay installed to $GOBIN/goplay"
  '';

in

{
  home.packages = with pkgs; [
    # Language Servers
    nil                                    # Nix LSP
    nixfmt-rfc-style                      # Nix formatter
    statix                                # Nix linter (anti-pattern detection)
    deadnix                               # Nix dead-code detector
    bash-language-server                  # Bash LSP
    marksman                             # Markdown LSP
    pyright                              # Python LSP
    gopls                                # Go LSP
    nodePackages.typescript-language-server # TypeScript LSP
    nodePackages.vscode-langservers-extracted # CSS/HTML/JSON LSP
    jdt-language-server                  # Java LSP
    ltex-ls                              # Grammar/Spell checker for EN/PT-BR

    # Node.js/TypeScript Development
    nodejs_22                            # Node.js runtime (includes npm)
    nodePackages.pnpm                    # Fast package manager
    yarn                                 # Alternative package manager
    bun                                  # Ultra-fast JS runtime & package manager
    nodePackages.typescript             # TypeScript compiler
    nodePackages.nodemon                # Development server with auto-restart
    
    # Formatting & Linting
    nodePackages.prettier               # Code formatter
    nodePackages.eslint                 # JavaScript/TypeScript linter
    nodePackages.eslint_d              # ESLint daemon for faster linting
    
    # Python Development
    (python3.withPackages (ps: with ps; [
      pylint                            # Python linter
      black                             # Python code formatter
      isort                             # Python import sorter
      flake8                            # Python style checker
      python-pptx                       # PowerPoint file creation/manipulation
    ]))
    uv                                  # Ultra-fast Python package manager
    
    # Go Development
    # The Go toolchain itself is pulled from unstable further down;
    # install-goplay is a host script (wraps `go install`) so it stays
    # on stable pkgs. Everything else here is Go tooling and lives on
    # unstable (see the `++ [ unstable-pkgs.* ]` block below) to stay
    # in sync with the unstable Go runtime.
    install-goplay                     # Script to install goplay (Go Playground client)

    # Rust Development
    rustc                              # Rust compiler
    cargo                              # Rust package manager
    rustfmt                            # Rust code formatter
    rust-analyzer                      # Rust LSP
    clippy                             # Rust linter
    cargo-watch                        # Auto-reload for Rust projects
    cargo-edit                         # Cargo add/remove/upgrade commands
    cargo-expand                       # Show macro expansion
    cargo-outdated                     # Check for outdated dependencies
    cargo-audit                        # Security vulnerability scanner
    cargo-deny                         # Cargo plugin for linting dependencies
    cargo-flamegraph                   # Flamegraph profiling
    cargo-udeps                        # Find unused dependencies
    cargo-bloat                        # Find what takes most space in binary
    cargo-nextest                      # Next-generation test runner
    cargo-tarpaulin                    # Code coverage tool
    cargo-criterion                    # Benchmarking

    # Java Development
    openjdk21                          # Java runtime
    maven                              # Java build tool
    gradle                             # Alternative Java build tool
    
    # Shell & Docker Development
    shellcheck                         # Shell script analysis
    hadolint                          # Dockerfile linter

    # Security Scanning
    gitleaks                         # Secret detection in source & git history
    trivy                            # Dependency & container vulnerability scanner
    
    # Build Tools & Compilers (needed for nvim-treesitter & LuaSnip)
    gcc                              # C compiler
    gnumake                          # Make build tool  
    cmake                            # Build system
    pkg-config                       # Package config tool
    tree-sitter                      # Parser generator for treesitter
    
    # Additional Development Tools
    gitui                             # Terminal UI for Git
    lazygit                           # Another terminal UI for Git
    git-filter-repo                   # Rewrite/filter git history
    gh                                # GitHub CLI
    docker-compose                    # Container orchestration
    nerdctl                           # Docker-compatible CLI for containerd
    tilt                              # Local Kubernetes development tool
    lazydocker                        # Terminal UI for Docker
    sqlite                            # Database for development
    
    # Database tools
    nodePackages.sql-formatter        # SQL formatter
    
    # API development
    httpie                           # Modern HTTP client
    bc                               # Arbitrary precision calculator
    jq                               # JSON processor
    openssl                          # TLS/SSL toolkit and crypto library
    openssl.dev                      # OpenSSL headers and pkg-config files
    curl.dev                         # libcurl headers and pkg-config files
    rdkafka                          # Apache Kafka C/C++ client library (for rdkafka-sys)
    rdkafka.dev                      # librdkafka headers and pkg-config files
    k6                               # Load testing tool
    websocat                         # WebSocket client (like curl for WebSockets)

    # Cloud & Networking
    rclone                           # Mount Google Drive (and other cloud storage) as local filesystem
    cloudflared                      # Cloudflare Tunnel client for exposing local services

    # Browser Automation & Testing
    playwright-driver.browsers       # Playwright with bundled browsers

    # Audio/Video Processing & Speech-to-Text
    ffmpeg                           # Audio/video conversion (needed for voice message transcription)
    whisper-cpp                      # Speech-to-text engine (Whisper.cpp - fast, local, ARM-native)

    # Architecture Diagramming (C4 model)
    plantuml-c4                      # PlantUML with C4 model library (includes plantuml)
    graphviz                         # Graph layout engine (required by PlantUML)

    # AI/ML Development
    install-qwen-code                # Script to install Qwen Code CLI tool
    install-gemini-cli               # Script to install Google Gemini CLI
  ] ++ [
    unstable-pkgs.opencode           # AI coding agent for the terminal (unstable for current release cadence)

    unstable-pkgs.semgrep            # Static analysis / SAST (from unstable — stable has Python 3.13 SSL issues)

    # Go toolchain pulled from unstable to get the newer runtime (stable
    # nixpkgs' default `go` lags). The companion tools follow so they're
    # built against the same Go stdlib as the runtime.
    unstable-pkgs.go                 # Go runtime
    unstable-pkgs.delve              # Go debugger
    unstable-pkgs.golangci-lint      # Go meta-linter
    unstable-pkgs.govulncheck        # Go vulnerability checker
    unstable-pkgs.gosec              # Go security analyzer
    unstable-pkgs.go-licenses        # Go dependency license checker
    unstable-pkgs.gotests            # Generate Go tests from source code
    unstable-pkgs.impl               # Generate method stubs for implementing an interface
  ];
  
  # Development-related programs
  programs = {
    # Git configuration (already configured in git.nix if exists)
    
    # Development shells
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        warn_timeout = "1h";
      };
    };
  };
  
  # Development environment variables
  home.sessionVariables = {
    # Node.js
    NODE_OPTIONS = "--max-old-space-size=4096";

    # Playwright (browser automation) - use Nix-provided browsers
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    
    # Go
    GOPATH = "$HOME/go";
    GOBIN = "$HOME/go/bin";

    # Rust
    CARGO_HOME = "$HOME/.cargo";
    RUSTUP_HOME = "$HOME/.rustup";

    # Python
    PYTHONDONTWRITEBYTECODE = "1";
    
    # Qwen Code configuration for local Ollama
    OPENAI_API_KEY = "dummy_key";  # Any value works for local
    OPENAI_BASE_URL = "http://localhost:11434/v1";
    OPENAI_MODEL = "qwen3-coder:latest";
    
    # Development paths
    PATH = "$PATH:$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin";
  };
  
  # Auto-install npm-based AI CLI tools if not present
  home.activation.installNpmAiTools = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    mkdir -p "$NPM_CONFIG_PREFIX/bin"
    # Add Node.js to PATH so npm post-install scripts can find 'node'
    export PATH="${pkgs.nodejs_22}/bin:$NPM_CONFIG_PREFIX/bin:$PATH"

    # Install Gemini CLI if not present
    if ! command -v gemini &> /dev/null; then
      echo "Installing Google Gemini CLI..."
      ${pkgs.nodejs_22}/bin/npm install -g @google/gemini-cli
    fi

    # Install dev-browser if not present
    if ! command -v dev-browser &> /dev/null; then
      echo "Installing dev-browser..."
      ${pkgs.nodejs_22}/bin/npm install -g dev-browser
    fi

    # Install OpenAI Codex CLI if not present
    if ! command -v codex &> /dev/null; then
      echo "Installing OpenAI Codex CLI..."
      ${pkgs.nodejs_22}/bin/npm install -g @openai/codex
    fi
  '';

  # Auto-install/update Cursor Agent CLI.
  # Relies on nix-ld (enabled in system/packages.nix) to run the prebuilt binary.
  home.activation.installCursorAgent = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export PATH="$HOME/.local/bin:${lib.makeBinPath [ pkgs.curl pkgs.gnutar pkgs.gzip pkgs.coreutils ]}:$PATH"
    if command -v cursor-agent &> /dev/null; then
      echo "Updating Cursor Agent CLI..."
      cursor-agent update || true
    else
      echo "Installing Cursor Agent CLI..."
      ${pkgs.curl}/bin/curl -fsS https://cursor.com/install | ${pkgs.bash}/bin/bash
    fi
  '';

  # XDG configuration for development tools
  xdg.configFile = {
    # Prettier configuration
    "prettier/.prettierrc.json".text = builtins.toJSON {
      semi = true;
      singleQuote = false;
      quoteProps = "as-needed";
      trailingComma = "es5";
      bracketSpacing = true;
      bracketSameLine = false;
      arrowParens = "always";
      printWidth = 80;
      tabWidth = 2;
      useTabs = false;
      endOfLine = "lf";
    };
    
    # ESLint configuration
    "eslint/.eslintrc.json".text = builtins.toJSON {
      env = {
        browser = true;
        es2021 = true;
        node = true;
      };
      extends = [
        "eslint:recommended"
        "@typescript-eslint/recommended"
      ];
      parser = "@typescript-eslint/parser";
      parserOptions = {
        ecmaVersion = 12;
        sourceType = "module";
      };
      plugins = [ "@typescript-eslint" ];
      rules = {
        indent = [ "error" 2 ];
        quotes = [ "error" "double" ];
        semi = [ "error" "always" ];
      };
    };
  };

}