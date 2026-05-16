{ pkgs, inputs, ... }:
let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # Wrap zed-editor without rebuilding it from source: symlinkJoin the
  # cached binary into a thin wrapper derivation, then makeWrapper only
  # the `zed` entry point. Keeps cache.nixos.org hits intact — only this
  # 30-second wrapper rebuilds when the injection script changes.
  zedWrapped =
    let
      zedPkg = unstable-pkgs.zed-editor;
    in
    pkgs.symlinkJoin {
      name = "zed-editor-${zedPkg.version}-wrapped";
      paths = [ zedPkg ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/zeditor \
          --run 'if [ -z "''${ANTHROPIC_API_KEY:-}" ] && [ -r /run/secrets/anthropic_api_key ]; then zed_anthropic_key="$(cat /run/secrets/anthropic_api_key)"; case "$zed_anthropic_key" in ANTHROPIC_API_KEY=*) export ANTHROPIC_API_KEY="''${zed_anthropic_key#ANTHROPIC_API_KEY=}" ;; *) export ANTHROPIC_API_KEY="$zed_anthropic_key" ;; esac; unset zed_anthropic_key; fi'
        # Convenience alias: the cached nixpkgs build only ships
        # `zeditor`, but historical muscle memory + the desktop file
        # both expect `zed` to work too.
        ln -s zeditor $out/bin/zed
      '';
      inherit (zedPkg) version meta;
    };
in
{
  programs.zed-editor = {
    enable = true;
    package = zedWrapped;

    # Nix owns settings.json — Zed cannot modify it at runtime.
    mutableUserSettings = false;
    mutableUserKeymaps = false;

    extensions = [
      "nix"
      "dockerfile"
      "docker-compose"
      "helm"
      "markdown-oxide"
      "markdownlint"
      "git-firefly" # syntax highlighting for git commit/config/rebase/diff/ignore/attributes
      "log" # tree-sitter syntax highlighting for .log files

      # Languages
      "html"
      "bash"
      "fish"
      "make"
      "toml"
      "gosum"
      "proto"

      # Color schemes
      "catppuccin"
      "rose-pine-theme"
      "kanagawa-themes"

      # Icon themes
      "material-icon-theme"
      "catppuccin-icons"
    ];

    userSettings = {
      agent_servers = {
        cursor = {
          type = "registry";
        };
        claude-acp = {
          type = "registry";
        };
      };
      session = {
        trust_all_worktrees = true;
      };
      vim_mode = true;
      ui_font_size = 20;
      buffer_font_size = 16;
      bottom_dock_layout = "full";
      project_panel = {
        dock = "left";
        show_diagnostics = "all";
      };
      tabs = {
        file_icons = true;
        show_diagnostics = "all";
      };
      diagnostics = {
        inline = {
          enabled = true;
          max_severity = null;
        };
      };
      theme = {
        mode = "system";
        light = "Catppuccin Latte";
        dark = "Catppuccin Mocha";
      };
      icon_theme = {
        mode = "system";
        light = "Material Icon Theme";
        dark = "Material Icon Theme";
      };
      title_bar = {
        show_sign_in = false;
      };
      terminal = {
        shell = {
          program = "${pkgs.fish}/bin/fish";
        };
      };

      languages = {
        Nix = {
          language_servers = [ "nil" ];
          formatter = {
            external = {
              command = "nixfmt";
              arguments = [ ];
            };
          };
          format_on_save = "on";
        };
        Markdown = {
          language_servers = [ "markdown-oxide" ];
          format_on_save = "off";
          soft_wrap = "editor_width";
        };
      };

      lsp = {
        yaml-language-server = {
          settings = {
            yaml = {
              keyOrdering = false;
              schemas = {
                "kubernetes" = [
                  "k8s/**/*.yaml"
                  "k8s/**/*.yml"
                  "kubernetes/**/*.yaml"
                  "kubernetes/**/*.yml"
                  "manifests/**/*.yaml"
                  "manifests/**/*.yml"
                ];
                "https://json.schemastore.org/github-workflow.json" = [
                  ".github/workflows/*.yaml"
                  ".github/workflows/*.yml"
                ];
                "https://json.schemastore.org/chart.json" = [
                  "**/Chart.yaml"
                ];
              };
            };
          };
        };
      };
    };
  };
}
