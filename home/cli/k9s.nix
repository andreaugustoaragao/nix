{
  pkgs,
  inputs,
  ...
}:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  home.packages = [
    unstable-pkgs.k9s
    unstable-pkgs.kdash
  ];

  xdg.configFile."k9s/views.yaml".text = ''
    views:
      v1/pods:
        columns:
          - NAME
          - CPU
          - MEM
          - STATUS
  '';

  xdg.configFile."k9s/config.yaml".text = ''
    k9s:
      ui:
        skin: tokyonight
  '';

  # Tokyo Night Storm skin. Static — doesn't follow system mode.
  xdg.configFile."k9s/skins/tokyonight.yaml".text = ''
    k9s:
      body:
        fgColor:    "#c0caf5"
        bgColor:    "#24283b"
        logoColor:  "#7aa2f7"
      prompt:
        fgColor:      "#c0caf5"
        bgColor:      "#24283b"
        suggestColor: "#565f89"
      info:
        fgColor:      "#bb9af7"
        sectionColor: "#a9b1d6"
      dialog:
        fgColor:            "#c0caf5"
        bgColor:            "#24283b"
        buttonFgColor:      "#1d202f"
        buttonBgColor:      "#7aa2f7"
        buttonFocusFgColor: "#1d202f"
        buttonFocusBgColor: "#bb9af7"
        labelFgColor:       "#e0af68"
        fieldFgColor:       "#c0caf5"
      frame:
        border:
          fgColor:    "#414868"
          focusColor: "#7aa2f7"
        menu:
          fgColor:     "#c0caf5"
          keyColor:    "#e0af68"
          numKeyColor: "#7aa2f7"
        crumbs:
          fgColor:     "#1d202f"
          bgColor:     "#7aa2f7"
          activeColor: "#1d202f"
        status:
          newColor:       "#7aa2f7"
          modifyColor:    "#e0af68"
          addColor:       "#9ece6a"
          pendingColor:   "#bb9af7"
          errorColor:     "#f7768e"
          highlightColor: "#bb9af7"
          killColor:      "#f7768e"
          completedColor: "#a9b1d6"
        title:
          fgColor:        "#c0caf5"
          bgColor:        "#24283b"
          highlightColor: "#7aa2f7"
          counterColor:   "#bb9af7"
          filterColor:    "#e0af68"
      views:
        charts:
          bgColor: "#24283b"
          defaultDialColors:
            - "#7aa2f7"
            - "#f7768e"
          defaultChartColors:
            - "#7aa2f7"
            - "#f7768e"
        table:
          fgColor:       "#c0caf5"
          bgColor:       "#24283b"
          cursorFgColor: "#1d202f"
          cursorBgColor: "#7aa2f7"
          header:
            fgColor:     "#e0af68"
            bgColor:     "#24283b"
            sorterColor: "#7aa2f7"
        xray:
          fgColor:         "#c0caf5"
          bgColor:         "#24283b"
          cursorColor:     "#3d59a1"
          cursorTextColor: "#c0caf5"
          graphicColor:    "#bb9af7"
        yaml:
          keyColor:   "#7aa2f7"
          colonColor: "#565f89"
          valueColor: "#c0caf5"
        logs:
          fgColor: "#c0caf5"
          bgColor: "#24283b"
          indicator:
            fgColor:        "#7aa2f7"
            bgColor:        "#24283b"
            toggleOnColor:  "#9ece6a"
            toggleOffColor: "#565f89"
  '';
}
