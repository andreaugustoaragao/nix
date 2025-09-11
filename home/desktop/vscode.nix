{ config, pkgs, lib, inputs, ... }:

{
  # Cursor IDE configuration (using vscode home manager module with cursor package)
  programs.vscode = {
    enable = true;
    package = pkgs.code-cursor.overrideAttrs (oldAttrs: {
      # Configure for Wayland and system decorations
      postInstall = (oldAttrs.postInstall or "") + ''
        # Create wrapper script for Wayland mode
        wrapProgram "$out/bin/cursor" \
          --add-flags "--enable-wayland-ime" \
          --add-flags "--ozone-platform-hint=auto" \
          --add-flags "--enable-features=UseOzonePlatform,WaylandWindowDecorations" \
          --add-flags "--disable-gpu-sandbox" \
          --add-flags "--disable-gpu-memory-buffer-compositor-resources" \
          --add-flags "--disable-one-copy-rasterizer" \
          --add-flags "--disable-features=UseSkiaRenderer,HardwareMediaKeyHandling,CalculateNativeWinOcclusion,BackForwardCache" \
          --add-flags "--enable-features=UseOzonePlatform,WaylandWindowDecorations,TurnOffStreamingMediaCachingOnBattery"
      '';
    });
    
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        # Language Support
        golang.go                                 # Go
        redhat.java                               # Java Language Support
        
        # Nix Language Support
        jnoortheen.nix-ide                        # Nix language support with formatting and error report
        bbenoist.nix                              # Classic Nix syntax support
        
        # Vim Extension
        vscodevim.vim                             # Vim keybindings
        
        # General Development
        redhat.vscode-yaml                        # YAML support
        timonwong.shellcheck                      # Shell script analysis
        hashicorp.terraform                       # Terraform support
        
        # Git Integration
        eamodio.gitlens                           # Enhanced Git capabilities
        
        # Productivity  
        pkief.material-icon-theme                 # Better file icons
      ];
      
      userSettings = {
        # Theme Configuration 
        # NOTE: For Kanagawa theme, install manually from VSCode marketplace:
        # 1. Open VSCode/Cursor
        # 2. Go to Extensions (Ctrl+Shift+X)
        # 3. Search for "Kanagawa Theme" by metaphore or "Kanagawa Dragon" by qiushaoxi
        # 4. Install and set as theme via Ctrl+Shift+P -> "Color Theme"
        "workbench.colorTheme" = "Default Dark+";  # Default until Kanagawa is installed
        "workbench.iconTheme" = "material-icon-theme";
        
        # Vim Configuration
        "vim.useSystemClipboard" = true;
        "vim.useCtrlKeys" = true;
        "vim.hlsearch" = true;
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
        ];
        "vim.leader" = "<space>";
        
        # Editor Configuration
        "editor.lineNumbers" = "relative";
        "editor.cursorSurroundingLines" = 8;
        "editor.scrollBeyondLastLine" = false;
        "editor.wordWrap" = "on";
        "editor.fontFamily" = "JetBrains Mono, 'JetBrainsMono Nerd Font', monospace";
        "editor.fontSize" = 14;
        "editor.fontLigatures" = true;
        "editor.renderWhitespace" = "boundary";
        "editor.rulers" = [80 120];
        
        # Python Configuration
        "python.defaultInterpreterPath" = "/run/current-system/sw/bin/python3";
        "python.terminal.activateEnvInCurrentTerminal" = true;
        
        # Go Configuration
        "go.toolsManagement.autoUpdate" = true;
        "go.useLanguageServer" = true;
        "go.formatTool" = "goimports";
        
        # TypeScript Configuration
        "typescript.preferences.importModuleSpecifier" = "relative";
        "typescript.updateImportsOnFileMove.enabled" = "always";
        
        # Java Configuration
        "java.home" = "/run/current-system/sw/lib/openjdk";
        "java.configuration.runtimes" = [
          {
            "name" = "JavaSE-21";
            "path" = "/run/current-system/sw/lib/openjdk";
            "default" = true;
          }
        ];
        
        # Nix Configuration
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "/run/current-system/sw/bin/nil";
        "nix.formatterPath" = "/run/current-system/sw/bin/nixfmt-rfc-style";
        "nix.serverSettings" = {
          "nil" = {
            "formatting" = {
              "command" = [ "/run/current-system/sw/bin/nixfmt-rfc-style" ];
            };
          };
        };
        
        # Terminal Configuration
        "terminal.integrated.shell.linux" = "/run/current-system/sw/bin/fish";
        "terminal.integrated.fontFamily" = "JetBrains Mono, 'JetBrainsMono Nerd Font'";
        
        # File Explorer
        "explorer.confirmDelete" = false;
        "explorer.confirmDragAndDrop" = false;
        
        # Git Configuration
        "git.enableSmartCommit" = true;
        "git.confirmSync" = false;
        "gitlens.codeLens.enabled" = false;
        
        # Wayland and Window Configuration
        "window.titleBarStyle" = "native";
        "window.menuBarVisibility" = "toggle";
        "window.autoDetectColorScheme" = true;
        
        # Miscellaneous
        "workbench.startupEditor" = "none";
        "telemetry.telemetryLevel" = "off";
        "update.mode" = "none";
        "extensions.autoCheckUpdates" = false;
      };
    };
  };
} 