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
    python3                             # Python runtime
    uv                                  # Ultra-fast Python package manager
    python3Packages.pylint              # Python linter
    python3Packages.black               # Python code formatter
    python3Packages.isort               # Python import sorter
    python3Packages.flake8              # Python style checker
    
    # Go Development  
    go                                  # Go runtime
    delve                              # Go debugger
    golangci-lint                      # Go meta-linter
    
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
    
    # AI/ML Development
    install-qwen-code                # Script to install Qwen Code CLI tool
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
    
    # Go
    GOPATH = "$HOME/go";
    GOBIN = "$HOME/go/bin";
    
    # Python
    PYTHONDONTWRITEBYTECODE = "1";
    
    # Qwen Code configuration for local Ollama
    OPENAI_API_KEY = "dummy_key";  # Any value works for local
    OPENAI_BASE_URL = "http://localhost:11434/v1";
    OPENAI_MODEL = "qwen3-coder:latest";
    
    # Development paths
    PATH = "$PATH:$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin";
  };
  
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