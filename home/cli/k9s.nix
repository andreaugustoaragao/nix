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
  ];

  xdg.configFile = {
    "k9s/views.yaml".text = ''
      views:
        v1/pods:
          columns:
            - NAME
            - CPU
            - MEM
            - STATUS
    '';

    "k9s/config.yaml".text = ''
      k9s:
        ui:
          skin: catppuccin-mocha
    '';

    # Catppuccin Mocha skin. Static — doesn't follow system mode.
    "k9s/skins/catppuccin-mocha.yaml".text = ''
      k9s:
        body:
          fgColor:    "#cdd6f4"
          bgColor:    "#1e1e2e"
          logoColor:  "#89b4fa"
        prompt:
          fgColor:      "#cdd6f4"
          bgColor:      "#1e1e2e"
          suggestColor: "#6c7086"
        info:
          fgColor:      "#cba6f7"
          sectionColor: "#bac2de"
        dialog:
          fgColor:            "#cdd6f4"
          bgColor:            "#1e1e2e"
          buttonFgColor:      "#1e1e2e"
          buttonBgColor:      "#89b4fa"
          buttonFocusFgColor: "#1e1e2e"
          buttonFocusBgColor: "#cba6f7"
          labelFgColor:       "#f9e2af"
          fieldFgColor:       "#cdd6f4"
        frame:
          border:
            fgColor:    "#585b70"
            focusColor: "#89b4fa"
          menu:
            fgColor:     "#cdd6f4"
            keyColor:    "#f9e2af"
            numKeyColor: "#89b4fa"
          crumbs:
            fgColor:     "#1e1e2e"
            bgColor:     "#89b4fa"
            activeColor: "#1e1e2e"
          status:
            newColor:       "#89b4fa"
            modifyColor:    "#f9e2af"
            addColor:       "#a6e3a1"
            pendingColor:   "#cba6f7"
            errorColor:     "#f38ba8"
            highlightColor: "#cba6f7"
            killColor:      "#f38ba8"
            completedColor: "#bac2de"
          title:
            fgColor:        "#cdd6f4"
            bgColor:        "#1e1e2e"
            highlightColor: "#89b4fa"
            counterColor:   "#cba6f7"
            filterColor:    "#f9e2af"
        views:
          charts:
            bgColor: "#1e1e2e"
            defaultDialColors:
              - "#89b4fa"
              - "#f38ba8"
            defaultChartColors:
              - "#89b4fa"
              - "#f38ba8"
          table:
            fgColor:       "#cdd6f4"
            bgColor:       "#1e1e2e"
            cursorFgColor: "#1e1e2e"
            cursorBgColor: "#89b4fa"
            header:
              fgColor:     "#f9e2af"
              bgColor:     "#1e1e2e"
              sorterColor: "#89b4fa"
          xray:
            fgColor:         "#cdd6f4"
            bgColor:         "#1e1e2e"
            cursorColor:     "#313244"
            cursorTextColor: "#cdd6f4"
            graphicColor:    "#cba6f7"
          yaml:
            keyColor:   "#89b4fa"
            colonColor: "#6c7086"
            valueColor: "#cdd6f4"
          logs:
            fgColor: "#cdd6f4"
            bgColor: "#1e1e2e"
            indicator:
              fgColor:        "#89b4fa"
              bgColor:        "#1e1e2e"
              toggleOnColor:  "#a6e3a1"
              toggleOffColor: "#6c7086"
    '';
  };
}
