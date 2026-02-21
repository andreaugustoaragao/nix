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

  # One-time setup script for Google Workspace MCP OAuth flow
  setup-gworkspace-mcp = pkgs.writeShellScriptBin "setup-gworkspace-mcp" ''
    set -euo pipefail

    SECRETS_DIR="/run/secrets"
    CLIENT_ID_FILE="$SECRETS_DIR/google_oauth_client_id"
    CLIENT_SECRET_FILE="$SECRETS_DIR/google_oauth_client_secret"

    doctor() {
      echo "=== Google Workspace MCP Doctor ==="
      local ok=true

      # Check sops secrets
      if [ -f "$CLIENT_ID_FILE" ] && [ -s "$CLIENT_ID_FILE" ]; then
        echo "[OK] Client ID secret exists"
      else
        echo "[FAIL] Missing $CLIENT_ID_FILE -- run: sudo nixos-rebuild switch"
        ok=false
      fi

      if [ -f "$CLIENT_SECRET_FILE" ] && [ -s "$CLIENT_SECRET_FILE" ]; then
        echo "[OK] Client Secret secret exists"
      else
        echo "[FAIL] Missing $CLIENT_SECRET_FILE -- run: sudo nixos-rebuild switch"
        ok=false
      fi

      # Check uv is available
      if command -v ${pkgs.uv}/bin/uv &>/dev/null; then
        echo "[OK] uv is available"
      else
        echo "[FAIL] uv not found"
        ok=false
      fi

      # Check OAuth token cache
      local token_dir="$HOME/.config/gworkspace-mcp"
      if [ -d "$token_dir" ] && ls "$token_dir"/token* &>/dev/null 2>&1; then
        echo "[OK] OAuth tokens cached in $token_dir"
      else
        echo "[WARN] No OAuth tokens found -- run: setup-gworkspace-mcp"
      fi

      # Check .mcp.json has google-workspace entry
      if [ -f "$HOME/.mcp.json" ] && ${pkgs.jq}/bin/jq -e '.mcpServers["google-workspace"]' "$HOME/.mcp.json" &>/dev/null; then
        echo "[OK] google-workspace in ~/.mcp.json"
      else
        echo "[FAIL] google-workspace not in ~/.mcp.json -- run: home-manager switch or nixos-rebuild switch"
        ok=false
      fi

      echo ""
      if $ok; then
        echo "All checks passed."
      else
        echo "Some checks failed. See above."
        exit 1
      fi
    }

    if [ "''${1:-}" = "doctor" ]; then
      doctor
      exit 0
    fi

    # Verify secrets exist
    if [ ! -f "$CLIENT_ID_FILE" ] || [ ! -s "$CLIENT_ID_FILE" ]; then
      echo "ERROR: Google OAuth Client ID not found at $CLIENT_ID_FILE"
      echo "Make sure secrets are added to sops and nixos-rebuild switch has been run."
      exit 1
    fi
    if [ ! -f "$CLIENT_SECRET_FILE" ] || [ ! -s "$CLIENT_SECRET_FILE" ]; then
      echo "ERROR: Google OAuth Client Secret not found at $CLIENT_SECRET_FILE"
      echo "Make sure secrets are added to sops and nixos-rebuild switch has been run."
      exit 1
    fi

    export GOOGLE_OAUTH_CLIENT_ID="$(cat "$CLIENT_ID_FILE")"
    export GOOGLE_OAUTH_CLIENT_SECRET="$(cat "$CLIENT_SECRET_FILE")"

    echo "Starting Google Workspace MCP OAuth flow..."
    echo "A browser window will open for Google consent."
    echo ""
    ${pkgs.uv}/bin/uvx --from gworkspace-mcp workspace setup
  '';
in

{
  home.packages = with pkgs; [
    # Language Servers
    nil                                    # Nix LSP
    nixfmt-rfc-style                      # Nix formatter
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
    go                                  # Go runtime
    delve                              # Go debugger
    golangci-lint                      # Go meta-linter

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
    
    # Build Tools & Compilers (needed for nvim-treesitter & LuaSnip)
    gcc                              # C compiler
    gnumake                          # Make build tool  
    cmake                            # Build system
    pkg-config                       # Package config tool
    tree-sitter                      # Parser generator for treesitter
    
    # Additional Development Tools
    gitui                             # Terminal UI for Git
    lazygit                           # Another terminal UI for Git
    gh                                # GitHub CLI
    docker-compose                    # Container orchestration
    sqlite                            # Database for development
    
    # Database tools
    nodePackages.sql-formatter        # SQL formatter
    
    # API development
    httpie                           # Modern HTTP client
    jq                               # JSON processor

    # Cloud Storage
    rclone                           # Mount Google Drive (and other cloud storage) as local filesystem

    # Browser Automation & Testing
    playwright-driver.browsers       # Playwright with bundled browsers

    # AI/ML Development
    install-qwen-code                # Script to install Qwen Code CLI tool
    install-gemini-cli               # Script to install Google Gemini CLI
    setup-gworkspace-mcp             # One-time OAuth setup for Google Workspace MCP
  ] ++ [
    unstable-pkgs.ollama             # Local AI model runner (from unstable)
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

  # Claude Code MCP server configuration (Playwright with Nix-managed paths)
  # --user-data-dir is required on NixOS because Playwright MCP tries to create
  # browser profile directories inside PLAYWRIGHT_BROWSERS_PATH (/nix/store/…)
  # which is read-only. We redirect profiles to a writable location.
  home.file.".mcp.json".text = builtins.toJSON {
    mcpServers = {
      playwright = {
        command = "bash";
        args = [
          "-c"
          "PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers} PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 exec npx @playwright/mcp@latest --browser chromium --executable-path ${unstable-pkgs.brave}/bin/brave --user-data-dir $HOME/.local/share/playwright-mcp/profiles"
        ];
      };
      google-workspace = {
        command = "bash";
        args = [
          "-c"
          "export GOOGLE_OAUTH_CLIENT_ID=$(cat /run/secrets/google_oauth_client_id) && export GOOGLE_OAUTH_CLIENT_SECRET=$(cat /run/secrets/google_oauth_client_secret) && exec ${pkgs.uv}/bin/uvx --from gworkspace-mcp workspace mcp"
        ];
      };
    };
  };
}