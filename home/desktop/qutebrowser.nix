{
  unstable-pkgs,
  ...
}:

{
  # Qutebrowser configuration using unstable version
  programs.qutebrowser = {
    enable = true;
    package = unstable-pkgs.qutebrowser;

    settings = {
      # General settings
      auto_save.session = true;
      changelog_after_upgrade = "major";
      completion = {
        height = "50%";
        show = "always";
        shrink = true;
      };

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

      # Colors - Catppuccin Mocha theme
      colors = {
        #webpage.darkmode.enabled = true;
        webpage.preferred_color_scheme = "dark";

        # Completion menu
        completion = {
          fg = "#cdd6f4"; # fujiWhite
          odd.bg = "#1e1e2e"; # sumiInk1
          even.bg = "#11111b"; # sumiInk0
          category = {
            fg = "#89b4fa"; # crystalBlue
            bg = "#1e1e2e"; # sumiInk1
            border = {
              top = "#585b70"; # sumiInk4
              bottom = "#585b70"; # sumiInk4
            };
          };
          item.selected = {
            fg = "#f9e2af"; # boatYellow2
            bg = "#313244"; # waveBlue2
            border = {
              top = "#89b4fa"; # crystalBlue
              bottom = "#89b4fa"; # crystalBlue
            };
            match.fg = "#a6e3a1"; # springGreen
          };
          match.fg = "#a6e3a1"; # springGreen
          scrollbar = {
            fg = "#cdd6f4"; # fujiWhite
            bg = "#1e1e2e"; # sumiInk1
          };
        };

        # Context menu
        contextmenu = {
          disabled = {
            fg = "#6c7086"; # fujiGray
            bg = "#1e1e2e"; # sumiInk1
          };
          menu = {
            fg = "#cdd6f4"; # fujiWhite
            bg = "#1e1e2e"; # sumiInk1
          };
          selected = {
            fg = "#f9e2af"; # boatYellow2
            bg = "#313244"; # waveBlue2
          };
        };

        # Downloads
        downloads = {
          bar.bg = "#1e1e2e"; # sumiInk1
          start = {
            fg = "#1e1e2e"; # sumiInk1
            bg = "#89b4fa"; # crystalBlue
          };
          stop = {
            fg = "#1e1e2e"; # sumiInk1
            bg = "#a6e3a1"; # springGreen
          };
          error.fg = "#f38ba8"; # samuraiRed
        };

        # Hints
        hints = {
          fg = "#1e1e2e"; # sumiInk1
          bg = "#f9e2af"; # boatYellow2
          match.fg = "#a6e3a1"; # springGreen
        };

        # Keyhint widget
        keyhint = {
          fg = "#cdd6f4"; # fujiWhite
          suffix.fg = "#f9e2af"; # boatYellow2
          bg = "#1e1e2e"; # sumiInk1
        };

        # Messages
        messages = {
          error = {
            fg = "#1e1e2e"; # sumiInk1
            bg = "#f38ba8"; # samuraiRed
            border = "#f38ba8"; # samuraiRed
          };
          warning = {
            fg = "#1e1e2e"; # sumiInk1
            bg = "#fab387"; # roninYellow
            border = "#fab387"; # roninYellow
          };
          info = {
            fg = "#cdd6f4"; # fujiWhite
            bg = "#1e1e2e"; # sumiInk1
            border = "#585b70"; # sumiInk4
          };
        };

        # Prompts
        prompts = {
          fg = "#cdd6f4"; # fujiWhite
          border = "#585b70"; # sumiInk4
          bg = "#1e1e2e"; # sumiInk1
          selected.bg = "#313244"; # waveBlue2
          selected.fg = "#f9e2af"; # boatYellow2
        };

        # Statusbar
        statusbar = {
          normal = {
            fg = "#cdd6f4"; # fujiWhite
            bg = "#1e1e2e"; # sumiInk1
          };
          insert = {
            fg = "#1e1e2e"; # sumiInk1
            bg = "#a6e3a1"; # springGreen
          };
          passthrough = {
            fg = "#1e1e2e"; # sumiInk1
            bg = "#89b4fa"; # crystalBlue
          };
          private = {
            fg = "#cdd6f4"; # fujiWhite
            bg = "#313244"; # sumiInk3
          };
          command = {
            fg = "#cdd6f4"; # fujiWhite
            bg = "#1e1e2e"; # sumiInk1
            private = {
              fg = "#cdd6f4"; # fujiWhite
              bg = "#313244"; # sumiInk3
            };
          };
          caret = {
            fg = "#1e1e2e"; # sumiInk1
            bg = "#f9e2af"; # boatYellow2
            selection = {
              fg = "#1e1e2e"; # sumiInk1
              bg = "#cba6f7"; # oniViolet
            };
          };
          progress.bg = "#89b4fa"; # crystalBlue
          url = {
            fg = "#cdd6f4"; # fujiWhite
            error.fg = "#f38ba8"; # samuraiRed
            hover.fg = "#89dceb"; # lightBlue
            success.http.fg = "#f9e2af"; # boatYellow2
            success.https.fg = "#a6e3a1"; # springGreen
            warn.fg = "#fab387"; # roninYellow
          };
        };

        # Tabs
        tabs = {
          bar.bg = "#1e1e2e"; # sumiInk1
          indicator = {
            start = "#89b4fa"; # crystalBlue
            stop = "#a6e3a1"; # springGreen
            error = "#f38ba8"; # samuraiRed
          };
          odd = {
            fg = "#6c7086"; # fujiGray
            bg = "#11111b"; # sumiInk0
          };
          even = {
            fg = "#6c7086"; # fujiGray
            bg = "#1e1e2e"; # sumiInk1
          };
          pinned = {
            even = {
              fg = "#cdd6f4"; # fujiWhite
              bg = "#1e1e2e"; # sumiInk1
            };
            odd = {
              fg = "#cdd6f4"; # fujiWhite
              bg = "#11111b"; # sumiInk0
            };
            selected = {
              even = {
                fg = "#f9e2af"; # boatYellow2
                bg = "#313244"; # waveBlue2
              };
              odd = {
                fg = "#f9e2af"; # boatYellow2
                bg = "#313244"; # waveBlue2
              };
            };
          };
          selected = {
            odd = {
              fg = "#f9e2af"; # boatYellow2
              bg = "#313244"; # waveBlue2
            };
            even = {
              fg = "#f9e2af"; # boatYellow2
              bg = "#313244"; # waveBlue2
            };
          };
        };

        # Tooltip
        tooltip = {
          fg = "#cdd6f4"; # fujiWhite
          bg = "#1e1e2e"; # sumiInk1
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

      # Fonts (matching system theme with Catppuccin palette)
      fonts = {
        default_family = "CaskaydiaCove Nerd Font";
        default_size = "11pt";
        web = {
          family = {
            standard = "Inter";
            serif = "Noto Serif";
            sans_serif = "Inter";
            fixed = "CaskaydiaCove Nerd Font";
          };
          size = {
            default = 16;
            default_fixed = 13;
          };
        };
      };

      # Hints
      hints = {
        border = "1px solid #cdd6f4"; # Catppuccin Mocha text
        chars = "asdfghjkl";
        uppercase = true;
      };

      # Input
      input = {
        insert_mode = {
          auto_enter = true;
          auto_leave = true;
          plugins = true;
        };
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
