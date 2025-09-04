{ config, pkgs, lib, ... }:

{
  # ST Terminal configuration based on nix-config
  environment.systemPackages = with pkgs; [
    (st.overrideAttrs (oldAttrs: rec {
      src = fetchgit {
        url = "https://git.suckless.org/st";
        rev = "refs/tags/0.9.2";
        sha256 = "pFyK4XvV5Z4gBja8J996zF6wkdgQCNVccqUJ5+ejB/w=";
      };
      
      # Additional dependencies for patches
      buildInputs = oldAttrs.buildInputs ++ [
        harfbuzz 
        xorg.libXrandr
      ];
      
      patches = [
        # Ligatures patch for programming fonts
        (fetchpatch {
          url = "https://st.suckless.org/patches/ligatures/0.8.3/st-ligatures-20200430-0.8.3.diff";
          sha256 = "vKiYU0Va/iSLhhT9IoUHGd62xRD/XtDDjK+08rSm1KE=";
        })

        # Alpha transparency support
        (fetchpatch {
          url = "https://st.suckless.org/patches/alpha/st-alpha-osc11-20220222-0.8.5.diff";
          sha256 = "Y8GDatq/1W86GKPJWzggQB7O85hXS0SJRva2atQ3upw=";
        })

        # Bold is not bright colors
        (fetchpatch {
          url = "https://st.suckless.org/patches/bold-is-not-bright/st-bold-is-not-bright-20190127-3be4cf1.diff";
          sha256 = "IhrTgZ8K3tcf5HqSlHm3GTacVJLOhO7QPho6SCGXTHw=";
        })

        # Font size adjustment with xrandr
        (fetchpatch {
          url = "https://st.suckless.org/patches/xrandrfontsize/xrandrfontsize-0.8.4-20211224-2f6e597.diff";
          sha256 = "CBgRsdA2c0XcBYpjpMPSIQG07iBHLpxLEXCqfgWFl7Y=";
        })

        # Desktop entry for application menus
        (fetchpatch {
          url = "https://st.suckless.org/patches/desktopentry/st-desktopentry-0.8.5.diff";
          sha256 = "JUFRFEHeUKwtvj8OV02CqHFYTsx+pvR3s+feP9P+ezo=";
        })

        # W3M image display support
        (fetchpatch {
          url = "https://st.suckless.org/patches/w3m/st-w3m-0.8.3.diff";
          sha256 = "nVSG8zuRt3oKQCndzm+3ykuRB1NMYyas0Ne3qCG59ok=";
        })

        # Undercurl support for terminal applications
        (fetchpatch {
          url = "https://st.suckless.org/patches/undercurl/st-undercurl-0.9-20240103.diff";
          sha256 = "9ReeNknxQJnu4l3kR+G3hfNU+oxGca5agqzvkulhaCg=";
        })
      ];
      
      # Use the custom config.h from the st directory
      configFile = writeText "config.def.h" (builtins.readFile ./st/config.h);
      postPatch = "${oldAttrs.postPatch}\n cp ${configFile} config.def.h";
    }))
  ];
}