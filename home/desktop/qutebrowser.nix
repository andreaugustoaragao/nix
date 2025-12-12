{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs) system;
    config.allowUnfree = true;
  };
in
{
  # Qutebrowser configuration using unstable version
  programs.qutebrowser = {
    enable = true;
    package = pkgs-unstable.qutebrowser;

    settings = {
      # General settings
      auto_save.session = true;
      changelog_after_upgrade = "major";
      completion.height = "50%";
      completion.show = "always";
      completion.shrink = true;

      # Content settings
      content = {
        blocking.method = "adblock"; # Use Brave's ABP-style adblocker
        blocking.adblock.lists = [
          "https://easylist.to/easylist/easylist.txt"
          "https://easylist.to/easylist/easyprivacy.txt"
          "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"
          "https://easylist.to/easylist/fanboy-annoyance.txt"
          "https://www.i-dont-care-about-cookies.eu/abp/"
        ];
        cookies.accept = "all";
        default_encoding = "utf-8";
        geolocation = "ask";
        headers.user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";
        javascript.enabled = true;
        javascript.clipboard = "access"; # Allow clipboard access
        
        # Note: Site-specific permissions are configured in extraConfig section below
        
        register_protocol_handler = "ask";
        tls.certificate_errors = "ask";
      };

      # Colors - Kanagawa theme
      colors = {
        #webpage.darkmode.enabled = true;
        webpage.preferred_color_scheme = "dark";

        # Completion menu
        completion = {
          fg = "#dcd7ba"; # fujiWhite
          odd.bg = "#1f1f28"; # sumiInk1
          even.bg = "#16161d"; # sumiInk0
          category = {
            fg = "#7e9cd8"; # crystalBlue
            bg = "#1f1f28"; # sumiInk1
            border = {
              top = "#54546d"; # sumiInk4
              bottom = "#54546d"; # sumiInk4
            };
          };
          item.selected = {
            fg = "#c0a36e"; # boatYellow2
            bg = "#2d4f67"; # waveBlue2
            border = {
              top = "#7e9cd8"; # crystalBlue
              bottom = "#7e9cd8"; # crystalBlue
            };
            match.fg = "#76946a"; # springGreen
          };
          match.fg = "#76946a"; # springGreen
          scrollbar = {
            fg = "#dcd7ba"; # fujiWhite
            bg = "#1f1f28"; # sumiInk1
          };
        };

        # Context menu
        contextmenu = {
          disabled = {
            fg = "#727169"; # fujiGray
            bg = "#1f1f28"; # sumiInk1
          };
          menu = {
            fg = "#dcd7ba"; # fujiWhite
            bg = "#1f1f28"; # sumiInk1
          };
          selected = {
            fg = "#c0a36e"; # boatYellow2
            bg = "#2d4f67"; # waveBlue2
          };
        };

        # Downloads
        downloads = {
          bar.bg = "#1f1f28"; # sumiInk1
          start = {
            fg = "#1f1f28"; # sumiInk1
            bg = "#7e9cd8"; # crystalBlue
          };
          stop = {
            fg = "#1f1f28"; # sumiInk1
            bg = "#76946a"; # springGreen
          };
          error.fg = "#e82424"; # samuraiRed
        };

        # Hints
        hints = {
          fg = "#1f1f28"; # sumiInk1
          bg = "#c0a36e"; # boatYellow2
          match.fg = "#76946a"; # springGreen
        };

        # Keyhint widget
        keyhint = {
          fg = "#dcd7ba"; # fujiWhite
          suffix.fg = "#c0a36e"; # boatYellow2
          bg = "#1f1f28"; # sumiInk1
        };

        # Messages
        messages = {
          error = {
            fg = "#1f1f28"; # sumiInk1
            bg = "#e82424"; # samuraiRed
            border = "#e82424"; # samuraiRed
          };
          warning = {
            fg = "#1f1f28"; # sumiInk1
            bg = "#ff9e3b"; # roninYellow
            border = "#ff9e3b"; # roninYellow
          };
          info = {
            fg = "#dcd7ba"; # fujiWhite
            bg = "#1f1f28"; # sumiInk1
            border = "#54546d"; # sumiInk4
          };
        };

        # Prompts
        prompts = {
          fg = "#dcd7ba"; # fujiWhite
          border = "#54546d"; # sumiInk4
          bg = "#1f1f28"; # sumiInk1
          selected.bg = "#2d4f67"; # waveBlue2
          selected.fg = "#c0a36e"; # boatYellow2
        };

        # Statusbar
        statusbar = {
          normal = {
            fg = "#dcd7ba"; # fujiWhite
            bg = "#1f1f28"; # sumiInk1
          };
          insert = {
            fg = "#1f1f28"; # sumiInk1
            bg = "#76946a"; # springGreen
          };
          passthrough = {
            fg = "#1f1f28"; # sumiInk1
            bg = "#7e9cd8"; # crystalBlue
          };
          private = {
            fg = "#dcd7ba"; # fujiWhite
            bg = "#363646"; # sumiInk3
          };
          command = {
            fg = "#dcd7ba"; # fujiWhite
            bg = "#1f1f28"; # sumiInk1
            private = {
              fg = "#dcd7ba"; # fujiWhite
              bg = "#363646"; # sumiInk3
            };
          };
          caret = {
            fg = "#1f1f28"; # sumiInk1
            bg = "#c0a36e"; # boatYellow2
            selection = {
              fg = "#1f1f28"; # sumiInk1
              bg = "#957fb8"; # oniViolet
            };
          };
          progress.bg = "#7e9cd8"; # crystalBlue
          url = {
            fg = "#dcd7ba"; # fujiWhite
            error.fg = "#e82424"; # samuraiRed
            hover.fg = "#7fb4ca"; # lightBlue
            success.http.fg = "#c0a36e"; # boatYellow2
            success.https.fg = "#76946a"; # springGreen
            warn.fg = "#ff9e3b"; # roninYellow
          };
        };

        # Tabs
        tabs = {
          bar.bg = "#1f1f28"; # sumiInk1
          indicator = {
            start = "#7e9cd8"; # crystalBlue
            stop = "#76946a"; # springGreen
            error = "#e82424"; # samuraiRed
          };
          odd = {
            fg = "#727169"; # fujiGray
            bg = "#16161d"; # sumiInk0
          };
          even = {
            fg = "#727169"; # fujiGray
            bg = "#1f1f28"; # sumiInk1
          };
          pinned = {
            even = {
              fg = "#dcd7ba"; # fujiWhite
              bg = "#1f1f28"; # sumiInk1
            };
            odd = {
              fg = "#dcd7ba"; # fujiWhite
              bg = "#16161d"; # sumiInk0
            };
            selected = {
              even = {
                fg = "#c0a36e"; # boatYellow2
                bg = "#2d4f67"; # waveBlue2
              };
              odd = {
                fg = "#c0a36e"; # boatYellow2
                bg = "#2d4f67"; # waveBlue2
              };
            };
          };
          selected = {
            odd = {
              fg = "#c0a36e"; # boatYellow2
              bg = "#2d4f67"; # waveBlue2
            };
            even = {
              fg = "#c0a36e"; # boatYellow2
              bg = "#2d4f67"; # waveBlue2
            };
          };
        };

        # Tooltip
        tooltip = {
          fg = "#dcd7ba"; # fujiWhite
          bg = "#1f1f28"; # sumiInk1
        };
      };

      # Downloads
      downloads = {
        location.directory = "~/downloads";
        location.prompt = false;
        remove_finished = 10000; # 10 seconds
      };

      # Editor
      editor.command = [
        "foot"
        "nvim"
        "{}"
      ];

      # Fonts (matching system theme with Kanagawa Nerd Font)
      fonts = {
        default_family = "CaskaydiaCove Nerd Font";
        default_size = "11pt";
        web.family.standard = "Inter";
        web.family.serif = "Noto Serif";
        web.family.sans_serif = "Inter";
        web.family.fixed = "CaskaydiaCove Nerd Font";
        web.size.default = 16;
        web.size.default_fixed = 13;
      };

      # Hints
      hints = {
        border = "1px solid #dcd7ba"; # Kanagawa foreground
        chars = "asdfghjkl";
        uppercase = true;
      };

      # Input
      input = {
        insert_mode.auto_enter = true;
        insert_mode.auto_leave = true;
        insert_mode.plugins = true;
      };

      # New instance handling for web apps
      new_instance_open_target = "window";

      # Qt settings
      qt = {
        force_platformtheme = "gtk3";
        highdpi = true;
      };

      # Scrolling
      scrolling = {
        bar = "when-searching";
        smooth = true;
      };

      # Statusbar
      statusbar = {
        position = "bottom";
        show = "never";
      };

      # Tabs
      tabs = {
        background = true;
        close_mouse_button = "middle";
        last_close = "close";
        max_width = -1;
        mousewheel_switching = false;
        new_position.related = "next";
        position = "top";
        select_on_remove = "next";
        show = "switching";
        title.format = "{audio}{index}: {current_title}";
        title.format_pinned = "{audio}{index}";
        wrap = true;
      };

      # URL settings
      url = {
        auto_search = "naive";
        default_page = "https://search.brave.com/";
        start_pages = [ "https://search.brave.com/" ];
      };

      # Window
      window = {
        hide_decoration = false;
        title_format = "{perc}{current_title}{title_sep}qutebrowser";
      };

      # Zoom
      zoom.default = "100%";
    };

    # Key bindings
    keyBindings = {
      normal = {
        # Navigation
        "J" = "tab-prev";
        "K" = "tab-next";
        "gh" = "home";

        # Downloads
        "gd" = "download-clear";

        # Developer tools
        "wi" = "devtools";

        # Bookmarks
        "M" = "bookmark-add";
        "gb" = "bookmark-list";

        # History
        "H" = "back";
        "L" = "forward";

        # Zoom
        "zi" = "zoom-in";
        "zo" = "zoom-out";
        "zz" = "zoom 100";
        "<Ctrl-=>" = "zoom-in";
        "<Ctrl-->" = "zoom-out";

        # View source
        "gf" = "view-source";

        # Print
        "gp" = "print";

        # Reload
        "R" = "reload -f";

        # Adblock update
        "gu" = "adblock-update";

        # Private browsing
        "tp" = "open -p";
        "wp" = "open -pw";
      };

      insert = {
        # Exit insert mode
        "<Ctrl-[>" = "mode-leave";
        "<Escape>" = "mode-leave";
      };
    };

    # Search engines
    searchEngines = {
      "DEFAULT" = "https://search.brave.com/search?q={}";
      "b" = "https://search.brave.com/search?q={}";
      "g" = "https://www.google.com/search?q={}";
      "ddg" = "https://duckduckgo.com/?q={}";
      "gh" = "https://github.com/search?q={}";
      "nix" = "https://search.nixos.org/packages?query={}";
      "nixops" = "https://search.nixos.org/options?query={}";
      "yt" = "https://www.youtube.com/results?search_query={}";
      "w" = "https://en.wikipedia.org/wiki/{}";
      "reddit" = "https://www.reddit.com/search/?q={}";
    };

    # Aliases
    aliases = {
      "q" = "close";
      "qa" = "quit";
      "w" = "session-save";
      "wq" = "quit --save";
      "wqa" = "quit --save";
    };

    # Extra config for URL-based patterns that can't be handled in settings
    extraConfig = ''
      # Set default permissions for all sites
      config.set('content.notifications.enabled', 'ask', '*')
      config.set('content.media.audio_capture', 'ask', '*')
      config.set('content.media.video_capture', 'ask', '*')
      config.set('content.media.audio_video_capture', 'ask', '*')
      
      # Site-specific notifications permissions
      config.set('content.notifications.enabled', True, 'https://web.whatsapp.com')
      config.set('content.notifications.enabled', True, 'https://teams.microsoft.com')
      config.set('content.notifications.enabled', True, 'https://grok.com')
      
      # Site-specific media permissions for video conferencing
      config.set('content.media.audio_capture', True, 'https://teams.microsoft.com')
      config.set('content.media.audio_capture', True, 'https://meet.google.com')
      config.set('content.media.audio_capture', True, 'https://zoom.us')
      
      config.set('content.media.video_capture', True, 'https://teams.microsoft.com')
      config.set('content.media.video_capture', True, 'https://meet.google.com')
      config.set('content.media.video_capture', True, 'https://zoom.us')
      
      config.set('content.media.audio_video_capture', True, 'https://teams.microsoft.com')
      config.set('content.media.audio_video_capture', True, 'https://meet.google.com')
      config.set('content.media.audio_video_capture', True, 'https://zoom.us')
    '';
  };

}

