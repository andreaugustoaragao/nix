{ pkgs, inputs, ... }:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  programs.zed-editor = {
    enable = true;
    package = pkgs-unstable.zed-editor;

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

      # Languages
      "html"
      "bash"
      "fish"
      "make"
      "gosum"
      "proto"

      # Color schemes
      "catppuccin"
      "tokyo-night"
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
      ui_font_size = 16;
      buffer_font_size = 15;
      theme = {
        mode = "system";
        light = "One Light";
        dark = "Gruvbox Dark Hard";
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
