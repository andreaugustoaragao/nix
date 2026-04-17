{ config, pkgs, lib, inputs, ... }:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  sqlite-viewer = pkgs.vscode-utils.buildVscodeMarketplaceExtension {
    mktplcRef = {
      name = "sqlite-viewer";
      publisher = "qwtel";
      version = "26.2.5";
      sha256 = "sha256-mPzgci1hgjCmdylQd6co/WLsJJGFl8FRjXsWWoqB5oQ=";
    };
  };

  markdown-editor = pkgs.vscode-utils.buildVscodeMarketplaceExtension {
    mktplcRef = {
      name = "markdown-editor";
      publisher = "zaaack";
      version = "0.1.9";
      sha256 = "sha256-aukUsWvqabRqx0Kgw3fmfwE9p4nZZf9Q58G5onZk1BA=";
    };
  };
in
{
  # VSCodium configuration
  programs.vscode = {
    enable = true;
    package = pkgs-unstable.vscodium.overrideAttrs (oldAttrs: {
      postInstall = (oldAttrs.postInstall or "") + ''
        wrapProgram "$out/bin/codium" \
          --set NIXOS_OZONE_WL 1 \
          --set ELECTRON_OZONE_PLATFORM_HINT auto
      '';
    });

    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        # AI
        anthropic.claude-code                     # Claude Code

        # Rust
        rust-lang.rust-analyzer                   # Rust language server
        tamasfe.even-better-toml                  # TOML support (Cargo.toml)
        serayuzgur.crates                         # Crate version management in Cargo.toml
        vadimcn.vscode-lldb                       # Rust/C++ debugger

        # Go
        golang.go                                 # Go language support

        # TypeScript / React / HTML / CSS
        dbaeumer.vscode-eslint                    # ESLint integration
        esbenp.prettier-vscode                    # Prettier code formatter
        formulahendry.auto-rename-tag             # Auto-rename paired HTML/JSX tags
        formulahendry.auto-close-tag              # Auto-close HTML/JSX tags
        bradlc.vscode-tailwindcss                 # Tailwind CSS IntelliSense
        christian-kohler.path-intellisense        # File path autocomplete
        christian-kohler.npm-intellisense         # JS module autocomplete in imports
        wix.vscode-import-cost                    # Display import size inline

        # Fish
        bmalehorn.vscode-fish                     # Fish shell syntax highlighting

        # Terraform
        hashicorp.terraform                       # Terraform language support

        # Nix
        jnoortheen.nix-ide                        # Nix language support with formatting
        bbenoist.nix                              # Classic Nix syntax support

        # Java
        redhat.java                               # Java language support

        # YAML / JSON
        redhat.vscode-yaml                        # YAML support

        # Shell
        timonwong.shellcheck                      # Shell script analysis

        # Markdown
        bierner.github-markdown-preview           # GitHub-style markdown preview
        bierner.markdown-mermaid                   # Mermaid diagram support
        bierner.markdown-emoji                    # Emoji rendering
        bierner.markdown-checkbox                 # Checkbox support
        bierner.markdown-footnotes                # Footnotes support
        bierner.markdown-preview-github-styles    # GitHub CSS styling
        yzhang.markdown-all-in-one               # Shortcuts, TOC, auto-preview

        # HTML
        ms-vscode.live-server                     # In-editor HTML preview

        # Git
        eamodio.gitlens                           # Enhanced Git capabilities

        # Editor Enhancements
        usernamehw.errorlens                      # Inline error/warning display
        gruntfuggly.todo-tree                     # TODO/FIXME/HACK tree view
        editorconfig.editorconfig                 # EditorConfig support
        streetsidesoftware.code-spell-checker     # Spell checker for code and comments

        # Vim
        vscodevim.vim                             # Vim keybindings

        # Docker / Kubernetes / Azure
        ms-azuretools.vscode-docker               # Dockerfile and docker-compose support
        ms-kubernetes-tools.vscode-kubernetes-tools # Kubernetes cluster management
        tim-koehler.helm-intellisense             # Helm chart IntelliSense

        # Themes
        enkia.tokyo-night                         # Tokyo Night color theme
        catppuccin.catppuccin-vsc                  # Catppuccin color theme
        catppuccin.catppuccin-vsc-icons            # Catppuccin icon theme

        # Database
        sqlite-viewer                             # SQLite database viewer

        # Markdown
        markdown-editor                           # WYSIWYG markdown editor

        # Productivity
        pkief.material-icon-theme                 # Better file icons
      ];

      userSettings = {
        # Theme (switch via Ctrl+Shift+P -> "Color Theme")
        # Available: "Monokai", "Tokyo Night", "Tokyo Night Storm", "Tokyo Night Light",
        #            "Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappe", "Catppuccin Latte"
        "workbench.colorTheme" = "Monokai";
        "workbench.iconTheme" = "material-icon-theme";

        # Vim
        "vim.useSystemClipboard" = true;
        "vim.useCtrlKeys" = true;
        "vim.hlsearch" = true;
        "vim.leader" = "<space>";
        "vim.sneak" = true;
        "vim.highlightedyank.enable" = true;
        "vim.camelCaseMotion.enable" = true;
        "vim.insertModeKeyBindings" = [
          {
            "before" = ["j" "j"];
            "after" = ["<Esc>"];
          }
        ];
        "vim.normalModeKeyBindingsNonRecursive" = [
          {
            "before" = ["<leader>" "w"];
            "commands" = ["workbench.action.files.save"];
          }
          {
            "before" = ["<leader>" "q"];
            "commands" = ["workbench.action.closeActiveEditor"];
          }
          {
            "before" = ["<leader>" "e"];
            "commands" = ["workbench.action.toggleSidebarVisibility"];
          }
          {
            "before" = ["<leader>" "f"];
            "commands" = ["workbench.action.quickOpen"];
          }
          {
            "before" = ["<leader>" "g"];
            "commands" = ["workbench.action.findInFiles"];
          }
        ];

        # Editor
        "editor.lineNumbers" = "relative";
        "editor.cursorSurroundingLines" = 8;
        "editor.scrollBeyondLastLine" = false;
        "editor.wordWrap" = "on";
        "editor.fontFamily" = "CaskaydiaMono Nerd Font, 'JetBrains Mono', monospace";
        "editor.fontSize" = 14;
        "editor.fontLigatures" = true;
        "editor.renderWhitespace" = "boundary";
        "editor.rulers" = [80 120];
        "editor.bracketPairColorization.enable" = true;
        "editor.guides.bracketPairs" = "active";
        "editor.stickyScroll.enabled" = true;
        "editor.linkedEditing" = true;
        "editor.formatOnSave" = true;
        "editor.minimap.enabled" = false;
        "editor.cursorBlinking" = "smooth";
        "editor.smoothScrolling" = true;
        "editor.inlayHints.enabled" = "onUnlessPressed";
        "editor.defaultFormatter" = "esbenp.prettier-vscode";

        # Files
        "files.autoSave" = "afterDelay";
        "files.autoSaveDelay" = 1000;
        "files.trimTrailingWhitespace" = true;
        "files.insertFinalNewline" = true;
        "files.trimFinalNewlines" = true;
        "files.exclude" = {
          "**/.git" = true;
          "**/.DS_Store" = true;
          "**/node_modules" = true;
          "**/target" = true;
          "**/__pycache__" = true;
          "**/.direnv" = true;
          "**/result" = true;
        };

        # Search
        "search.exclude" = {
          "**/node_modules" = true;
          "**/target" = true;
          "**/dist" = true;
          "**/build" = true;
          "**/.direnv" = true;
          "**/result" = true;
          "**/*.min.js" = true;
        };

        # Per-language formatters
        "[rust]" = {
          "editor.defaultFormatter" = "rust-lang.rust-analyzer";
        };
        "[go]" = {
          "editor.defaultFormatter" = "golang.go";
        };
        "[nix]" = {
          "editor.defaultFormatter" = "jnoortheen.nix-ide";
        };
        "[terraform]" = {
          "editor.defaultFormatter" = "hashicorp.terraform";
        };
        "[fish]" = {
          "editor.defaultFormatter" = null;
          "editor.formatOnSave" = false;
        };
        "[toml]" = {
          "editor.defaultFormatter" = "tamasfe.even-better-toml";
        };
        "[markdown]" = {
          "editor.formatOnSave" = false;
          "editor.wordWrap" = "on";
        };

        # Python
        "python.defaultInterpreterPath" = "${pkgs.python3}/bin/python3";
        "python.terminal.activateEnvInCurrentTerminal" = true;

        # Go
        "go.toolsManagement.autoUpdate" = true;
        "go.useLanguageServer" = true;
        "go.formatTool" = "goimports";
        "go.lintTool" = "golangci-lint";
        "go.testFlags" = ["-v"];
        "go.diagnostic.vulncheck" = "Imports";

        # Rust
        "rust-analyzer.check.command" = "clippy";
        "rust-analyzer.rustfmt.extraArgs" = [ "+nightly" ];
        "rust-analyzer.cargo.allFeatures" = true;
        "rust-analyzer.procMacro.enable" = true;
        "rust-analyzer.inlayHints.chainingHints.enable" = true;
        "rust-analyzer.inlayHints.parameterHints.enable" = true;
        "rust-analyzer.inlayHints.typeHints.enable" = true;

        # TypeScript / React
        "typescript.preferences.importModuleSpecifier" = "relative";
        "typescript.updateImportsOnFileMove.enabled" = "always";
        "javascript.updateImportsOnFileMove.enabled" = "always";
        "typescript.suggest.autoImports" = true;
        "javascript.suggest.autoImports" = true;
        "emmet.includeLanguages" = {
          "javascript" = "javascriptreact";
          "typescript" = "typescriptreact";
        };
        "emmet.triggerExpansionOnTab" = true;

        # ESLint
        "eslint.validate" = [
          "javascript"
          "javascriptreact"
          "typescript"
          "typescriptreact"
        ];
        "eslint.codeActionsOnSave.mode" = "all";

        # Tailwind CSS
        "tailwindCSS.emmetCompletions" = true;

        # Java
        "java.home" = "${pkgs.openjdk21}/lib/openjdk";
        "java.configuration.runtimes" = [
          {
            "name" = "JavaSE-21";
            "path" = "${pkgs.openjdk21}/lib/openjdk";
            "default" = true;
          }
        ];

        # Nix
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "${pkgs.nil}/bin/nil";
        "nix.formatterPath" = "${pkgs.nixfmt-rfc-style}/bin/nixfmt-rfc-style";
        "nix.serverSettings" = {
          "nil" = {
            "formatting" = {
              "command" = [ "${pkgs.nixfmt-rfc-style}/bin/nixfmt-rfc-style" ];
            };
          };
        };

        # Terraform
        "terraform.languageServer.enable" = true;
        "terraform.experimentalFeatures.validateOnSave" = true;

        # Terminal
        "terminal.integrated.defaultProfile.linux" = "fish";
        "terminal.integrated.profiles.linux" = {
          "fish" = {
            "path" = "${pkgs.fish}/bin/fish";
          };
        };
        "terminal.integrated.fontFamily" = "CaskaydiaMono Nerd Font, 'JetBrains Mono'";
        "terminal.integrated.scrollback" = 10000;

        # Error Lens
        "errorLens.enabledDiagnosticLevels" = ["error" "warning"];
        "errorLens.delay" = 500;

        # Todo Tree
        "todo-tree.general.tags" = ["TODO" "FIXME" "HACK" "BUG" "XXX"];
        "todo-tree.highlights.defaultHighlight" = {
          "type" = "text-and-comment";
          "foreground" = "#ffb86c";
        };

        # Spell Checker
        "cSpell.enableFiletypes" = ["nix" "fish" "terraform" "toml" "markdown"];
        "cSpell.userWords" = ["nixos" "nixpkgs" "mkif" "mkmerge" "mkdefault" "flake"];

        # File Explorer
        "explorer.confirmDelete" = false;
        "explorer.confirmDragAndDrop" = false;
        "explorer.compactFolders" = false;

        # Git
        "git.enableSmartCommit" = true;
        "git.confirmSync" = false;
        "git.autofetch" = true;
        "gitlens.codeLens.enabled" = false;


        # Claude Code
        "claudeCode.allowDangerouslySkipPermissions" = true;
        "claudeCode.initialPermissionMode" = "bypassPermissions";
        "claudeCode.preferredLocation" = "sidebar";

        # Auto-preview
        "workbench.editorAssociations" = {
          "*.md" = "vscode.markdown.preview.editor";
          "*.html" = "livePreview.editor.preview";
        };

        # Performance
        "files.watcherExclude" = {
          "**/.git/objects/**" = true;
          "**/.git/subtree-cache/**" = true;
          "**/node_modules/**" = true;
          "**/target/**" = true;
          "**/.direnv/**" = true;
          "**/result/**" = true;
          "**/dist/**" = true;
          "**/build/**" = true;
          "**/.terraform/**" = true;
          "**/.minikube/**" = true;
        };
        "search.followSymlinks" = false;
        "typescript.tsserver.maxTsServerMemory" = 2048;
        "git.decorations.enabled" = false;
        "extensions.experimental.affinity" = {
          "rust-lang.rust-analyzer" = 1;
          "dbaeumer.vscode-eslint" = 2;
          "redhat.java" = 3;
        };
        "editor.largeFileOptimizations" = true;
        "files.maxMemoryForLargeFilesMB" = 512;

        # Miscellaneous
        "workbench.startupEditor" = "none";
        "workbench.list.smoothScrolling" = true;
        "telemetry.telemetryLevel" = "off";
        "update.mode" = "none";
        "extensions.autoCheckUpdates" = false;
        "breadcrumbs.enabled" = true;
      };
    };
  };
}
