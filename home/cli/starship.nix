{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Catppuccin Mocha + Latte palettes, mirrored from the official
  # catppuccin/starship snippet. Defined once so module styles can
  # reference colors by semantic name ("fg:blue", "fg:text") and the
  # whole prompt repaints when the active palette flips light/dark.
  palettes = {
    mocha = {
      rosewater = "#f5e0dc";
      flamingo = "#f2cdcd";
      pink = "#f5c2e7";
      mauve = "#cba6f7";
      red = "#f38ba8";
      maroon = "#eba0ac";
      peach = "#fab387";
      yellow = "#f9e2af";
      green = "#a6e3a1";
      teal = "#94e2d5";
      sky = "#89dceb";
      sapphire = "#74c7ec";
      blue = "#89b4fa";
      lavender = "#b4befe";
      text = "#cdd6f4";
      subtext1 = "#bac2de";
      subtext0 = "#a6adc8";
      overlay2 = "#9399b2";
      overlay1 = "#7f849c";
      overlay0 = "#6c7086";
      surface2 = "#585b70";
      surface1 = "#45475a";
      surface0 = "#313244";
      base = "#1e1e2e";
      mantle = "#181825";
      crust = "#11111b";
    };
    latte = {
      rosewater = "#dc8a78";
      flamingo = "#dd7878";
      pink = "#ea76cb";
      mauve = "#8839ef";
      red = "#d20f39";
      maroon = "#e64553";
      peach = "#fe640b";
      yellow = "#df8e1d";
      green = "#40a02b";
      teal = "#179299";
      sky = "#04a5e5";
      sapphire = "#209fb5";
      blue = "#1e66f5";
      lavender = "#7287fd";
      text = "#4c4f69";
      subtext1 = "#5c5f77";
      subtext0 = "#6c6f85";
      overlay2 = "#7c7f93";
      overlay1 = "#8c8fa1";
      overlay0 = "#9ca0b0";
      surface2 = "#acb0be";
      surface1 = "#bcc0cc";
      surface0 = "#ccd0da";
      base = "#eff1f5";
      mantle = "#e6e9ef";
      crust = "#dce0e8";
    };
  };

  mkConfig = paletteName: palette: {
    palette = "catppuccin_${paletteName}";
    palettes."catppuccin_${paletteName}" = palette;

    # Three-line framed prompt:
    #   ╭─  $user at $host on  $os $version ❄
    #   │  $directory git/lang badges
    #   ╰─> typed command
    # Frame in peach; username green, hostname red, snowflake red,
    # character green on success / red on error.
    format = ''
      [╭─](fg:peach)$username at $hostname on $os
      [│ ](fg:peach)$directory$git_branch$git_status$cmd_duration$all$docker_context
      [╰─](fg:peach)$character'';

    username = {
      show_always = true;
      style_user = "fg:green";
      style_root = "fg:red";
      format = "[ $user]($style)";
    };

    hostname = {
      ssh_only = false;
      style = "fg:red";
      format = "[$hostname]($style)";
    };

    os = {
      disabled = false;
      style = "fg:text";
      format = "[$name $version]($style) [❄](fg:red)";
    };

    directory = {
      style = "fg:yellow";
      format = "[$path]($style)[$read_only]($read_only_style) ";
    };

    git_branch = {
      symbol = " ";
      style = "fg:mauve";
      format = "[$symbol$branch(:$remote_branch)]($style) ";
    };
    git_status = {
      style = "fg:red";
      format = "[($all_status$ahead_behind)]($style) ";
    };

    cmd_duration = {
      style = "fg:yellow";
      format = "[$duration]($style) ";
    };

    golang = {
      symbol = "";
      style = "fg:blue";
      format = "[$symbol($version)]($style) ";
    };
    java.format = "[ ($version)]($style) ";

    docker_context = {
      style = "fg:blue";
      format = "[ 󰡨 ($context) ]($style)";
    };

    character = {
      success_symbol = "[> ](fg:green)";
      error_symbol = "[> ](fg:red)";
    };

    # We manage our own line breaks in the top-level format string;
    # the line_break module would add an extra one before $character.
    line_break.disabled = true;
    gcloud.disabled = true;
  };

  tomlFormat = pkgs.formats.toml { };
in

{
  # Manage starship.toml ourselves (via STARSHIP_CONFIG) so we can swap
  # the whole config file between Mocha/Latte on color-scheme toggle.
  # programs.starship.enable would clobber that with its own
  # single-file output, so we wire the shell init lines manually.
  home.packages = [ pkgs.starship ];

  programs.zsh.initContent = lib.mkAfter ''
    eval "$(${pkgs.starship}/bin/starship init zsh)"
  '';

  programs.fish.interactiveShellInit = lib.mkAfter ''
    ${pkgs.starship}/bin/starship init fish | source
  '';

  home.sessionVariables.STARSHIP_CONFIG = "${config.xdg.configHome}/starship/starship.toml";

  # Both palette variants as immutable store files. The active config
  # at ~/.config/starship/starship.toml is a writable symlink to one
  # of these, flipped by darkman (see home/services/darkman.nix) on
  # color-scheme toggle and seeded by the activation hook below.
  xdg.configFile = {
    "starship/starship.mocha.toml".source = tomlFormat.generate "starship.mocha.toml" (
      mkConfig "mocha" palettes.mocha
    );
    "starship/starship.latte.toml".source = tomlFormat.generate "starship.latte.toml" (
      mkConfig "latte" palettes.latte
    );
  };

  home.activation.starshipTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target=starship.mocha.toml
    if mode=$(${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null); then
      case "$mode" in
        *prefer-light*) target=starship.latte.toml ;;
      esac
    fi
    ${pkgs.coreutils}/bin/ln -sfn "$target" "$HOME/.config/starship/starship.toml"
  '';
}
