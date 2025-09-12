{ config, pkgs, lib, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };
in
{
  # Firefox Browser configuration using unstable version
  programs.firefox = {
    enable = true;
    package = pkgs-unstable.firefox;
    
    # Policies to enable extensions by default
    policies = {
      ExtensionSettings = {
        # uBlock Origin
        "uBlock0@raymondhill.net" = {
          installation_mode = "force_installed";
          allowed_types = ["extension"];
          default_area = "menupanel";
          permissions = ["<all_urls>"];
        };
        # Bitwarden
        "{446900e4-71c2-419f-a6a7-df9c091e268b}" = {
          installation_mode = "force_installed";
          allowed_types = ["extension"];
          default_area = "menupanel";
          permissions = ["<all_urls>"];
        };
        # Vimium
        "{d7742d87-e61d-4b78-b8a1-b469842139fa}" = {
          installation_mode = "force_installed";
          allowed_types = ["extension"];
          default_area = "menupanel";
          permissions = ["<all_urls>"];
        };
        # Dark Reader
        "addon@darkreader.org" = {
          installation_mode = "force_installed";
          allowed_types = ["extension"];
          default_area = "menupanel";
          permissions = ["<all_urls>"];
        };
        # Kanagawa Theme
        "{26690e10-862d-456f-8bf2-50117a3cb206}" = {
          installation_mode = "force_installed";
          allowed_types = ["theme"];
        };
        # Disable configuration prompts and setup wizard
        "*" = {
          installation_mode = "blocked";
        };
      };
      
      # Search engine configuration
      SearchEngines = {
        Default = "Brave";
        Add = [
          {
            Name = "Brave";
            URLTemplate = "https://search.brave.com/search?q={searchTerms}";
            Method = "GET";
            IconURL = "https://brave.com/static-assets/images/brave-favicon.png";
            Alias = "brave";
            Description = "Brave Search";
            SuggestURLTemplate = "https://search.brave.com/api/suggest?q={searchTerms}";
          }
        ];
      };
    };
    
    profiles = {
      default = {
        id = 0;
        name = "default";
        isDefault = true;
        
        extensions.packages = with inputs.firefox-addons.packages.${pkgs.system}; [
          bitwarden
          ublock-origin
          vimium
          darkreader
        ];
        
        settings = {
          # Enable userChrome.css
          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
          
          # Compact UI
          "browser.compactmode.show" = true;
          "browser.uidensity" = 1;
          
          # Enable WebGL
          "webgl.force-enabled" = true;
          
          # Enable hardware acceleration
          "gfx.webrender.all" = true;
          "media.ffmpeg.vaapi.enabled" = true;
          "media.hardware-video-decoding.force-enabled" = true;
          
          # Wayland support
          "widget.use-xdg-desktop-portal.file-picker" = 1;
          "widget.use-xdg-desktop-portal.mime-handler" = 1;
          
          # Privacy settings
          "privacy.trackingprotection.enabled" = true;
          "privacy.trackingprotection.socialtracking.enabled" = true;
          "privacy.donottrackheader.enabled" = true;
          
          # Disable telemetry
          "toolkit.telemetry.enabled" = false;
          "toolkit.telemetry.unified" = false;
          "datareporting.healthreport.uploadEnabled" = false;
          "datareporting.policy.dataSubmissionEnabled" = false;
          
          # Disable default browser check
          "browser.shell.checkDefaultBrowser" = false;
          
          # Disable first-run configuration prompts
          "browser.startup.homepage_override.mstone" = "ignore";
          "startup.homepage_welcome_url" = "";
          "startup.homepage_welcome_url.additional" = "";
          "browser.aboutwelcome.enabled" = false;
          
          # Disable embedded password management
          "signon.rememberSignons" = false;
          "signon.autofillForms" = false;
          "signon.generation.enabled" = false;
          
          # Performance optimizations for faster startup
          "browser.startup.preXulSkeletonUI" = false; # Disable startup skeleton UI for faster launch
          "browser.tabs.remote.autostart" = true; # Enable e10s multiprocess
          "dom.ipc.processCount" = 8; # Increase process count for better performance
          "browser.preferences.defaultPerformanceSettings.enabled" = false;
          "dom.ipc.processCount.webIsolated" = 4; # Isolated web content processes
          "fission.autostart" = true; # Enable Fission for better security and performance
          "browser.sessionstore.restore_pinned_tabs_on_demand" = true; # Load pinned tabs on demand
          "browser.sessionstore.restore_tabs_lazily" = true; # Load tabs lazily
          "network.dns.disablePrefetch" = false; # Allow DNS prefetching for faster page loads
          "network.predictor.enabled" = true; # Enable network predictor
          "network.prefetch-next" = true; # Prefetch next page links
          "browser.cache.disk.enable" = true; # Enable disk cache
          "browser.cache.memory.enable" = true; # Enable memory cache
          "browser.cache.memory.capacity" = 204800; # Set memory cache to 200MB
          "content.notify.interval" = 100000; # Reduce content notification frequency
          "nglayout.initialpaint.delay" = 0; # Remove initial paint delay
          
          # Set Brave Search as default search engine and homepage
          "browser.startup.homepage" = "https://search.brave.com";
          "browser.newtabpage.enabled" = false; # Use custom homepage instead of new tab page
        };
        
        userChrome = ''
          /* Hide the navigation toolbar and bookmarks bar by default */
          #nav-bar {
            margin-top: -40px !important;
            transition: margin-top 0.3s ease !important;
            z-index: 1000 !important;
          }
          
          /* Hide bookmarks toolbar */
          #PersonalToolbar {
            visibility: collapse !important;
            margin-top: -30px !important;
            transition: all 0.3s ease !important;
          }
          
          /* Show navigation toolbar and bookmarks on hover */
          #navigator-toolbox:hover #nav-bar,
          #nav-bar:focus-within {
            margin-top: 0px !important;
          }
          
          #navigator-toolbox:hover #PersonalToolbar {
            visibility: visible !important;
            margin-top: 0px !important;
          }
          
          /* Hide tab bar when only one tab (optional) */
          #TabsToolbar {
            visibility: collapse !important;
          }
          
          /* Ensure tabs are visible when multiple tabs exist */
          #tabbrowser-tabs[hasadjacentnewtabbutton="false"] ~ #TabsToolbar,
          #tabbrowser-tabs:not([hasadjacentnewtabbutton]) ~ #TabsToolbar {
            visibility: visible !important;
          }
          
          /* Hide window controls on hover area */
          #navigator-toolbox:hover .titlebar-buttonbox-container {
            opacity: 1 !important;
          }
          
          /* Smooth transitions for better UX */
          #navigator-toolbox {
            transition: all 0.3s ease !important;
          }
          
          /* Fix potential z-index issues */
          #main-window[tabsintitlebar="true"]:not([extradragspace="true"]) #TabsToolbar {
            opacity: 0 !important;
            pointer-events: none !important;
          }
          
          #main-window[tabsintitlebar="true"]:not([extradragspace="true"]) #navigator-toolbox:hover #TabsToolbar {
            opacity: 1 !important;
            pointer-events: auto !important;
          }
        '';
      };
      
      app = {
        id = 1;
        name = "app";
        isDefault = false;
        
        extensions.packages = with inputs.firefox-addons.packages.${pkgs.system}; [
          bitwarden
          ublock-origin
          vimium
        ];
        
        settings = {
          # Enable userChrome.css
          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
          
          # Compact UI
          "browser.compactmode.show" = true;
          "browser.uidensity" = 1;
          
          # Enable WebGL
          "webgl.force-enabled" = true;
          
          # Enable hardware acceleration
          "gfx.webrender.all" = true;
          "media.ffmpeg.vaapi.enabled" = true;
          "media.hardware-video-decoding.force-enabled" = true;
          
          # Wayland support
          "widget.use-xdg-desktop-portal.file-picker" = 1;
          "widget.use-xdg-desktop-portal.mime-handler" = 1;
          
          # Privacy settings
          "privacy.trackingprotection.enabled" = true;
          "privacy.trackingprotection.socialtracking.enabled" = true;
          "privacy.donottrackheader.enabled" = true;
          
          # Disable telemetry
          "toolkit.telemetry.enabled" = false;
          "toolkit.telemetry.unified" = false;
          "datareporting.healthreport.uploadEnabled" = false;
          "datareporting.policy.dataSubmissionEnabled" = false;
          
          # Disable default browser check
          "browser.shell.checkDefaultBrowser" = false;
          
          # Disable first-run configuration prompts
          "browser.startup.homepage_override.mstone" = "ignore";
          "startup.homepage_welcome_url" = "";
          "startup.homepage_welcome_url.additional" = "";
          "browser.aboutwelcome.enabled" = false;
          
          # Disable embedded password management
          "signon.rememberSignons" = false;
          "signon.autofillForms" = false;
          "signon.generation.enabled" = false;
          
          # Performance optimizations for faster startup
          "browser.startup.preXulSkeletonUI" = false; # Disable startup skeleton UI for faster launch
          "browser.tabs.remote.autostart" = true; # Enable e10s multiprocess
          "dom.ipc.processCount" = 8; # Increase process count for better performance
          "browser.preferences.defaultPerformanceSettings.enabled" = false;
          "dom.ipc.processCount.webIsolated" = 4; # Isolated web content processes
          "fission.autostart" = true; # Enable Fission for better security and performance
          "browser.sessionstore.restore_pinned_tabs_on_demand" = true; # Load pinned tabs on demand
          "browser.sessionstore.restore_tabs_lazily" = true; # Load tabs lazily
          "network.dns.disablePrefetch" = false; # Allow DNS prefetching for faster page loads
          "network.predictor.enabled" = true; # Enable network predictor
          "network.prefetch-next" = true; # Prefetch next page links
          "browser.cache.disk.enable" = true; # Enable disk cache
          "browser.cache.memory.enable" = true; # Enable memory cache
          "browser.cache.memory.capacity" = 204800; # Set memory cache to 200MB
          "content.notify.interval" = 100000; # Reduce content notification frequency
          "nglayout.initialpaint.delay" = 0; # Remove initial paint delay
          
          # App profile specific settings - no history and no session restore
          "places.history.enabled" = false;
          "browser.privatebrowsing.autostart" = false;
          "privacy.history.custom" = true;
          "browser.formfill.enable" = false;
          "browser.sessionstore.resume_from_crash" = false;
          "browser.sessionstore.restore_on_demand" = false;
          "browser.startup.page" = 0; # Start with blank page
          "browser.sessionstore.max_resumed_crashes" = 0;
          "browser.sessionstore.max_tabs_undo" = 0;
          "browser.sessionstore.max_windows_undo" = 0;
        };
        
        userChrome = ''
          /* Hide the navigation toolbar and bookmarks bar by default */
          #nav-bar {
            margin-top: -40px !important;
            transition: margin-top 0.3s ease !important;
            z-index: 1000 !important;
          }
          
          /* Hide bookmarks toolbar */
          #PersonalToolbar {
            visibility: collapse !important;
            margin-top: -30px !important;
            transition: all 0.3s ease !important;
          }
          
          /* Show navigation toolbar and bookmarks on hover */
          #navigator-toolbox:hover #nav-bar,
          #nav-bar:focus-within {
            margin-top: 0px !important;
          }
          
          #navigator-toolbox:hover #PersonalToolbar {
            visibility: visible !important;
            margin-top: 0px !important;
          }
          
          /* Hide tab bar when only one tab (optional) */
          #TabsToolbar {
            visibility: collapse !important;
          }
          
          /* Ensure tabs are visible when multiple tabs exist */
          #tabbrowser-tabs[hasadjacentnewtabbutton="false"] ~ #TabsToolbar,
          #tabbrowser-tabs:not([hasadjacentnewtabbutton]) ~ #TabsToolbar {
            visibility: visible !important;
          }
          
          /* Hide window controls on hover area */
          #navigator-toolbox:hover .titlebar-buttonbox-container {
            opacity: 1 !important;
          }
          
          /* Smooth transitions for better UX */
          #navigator-toolbox {
            transition: all 0.3s ease !important;
          }
          
          /* Fix potential z-index issues */
          #main-window[tabsintitlebar="true"]:not([extradragspace="true"]) #TabsToolbar {
            opacity: 0 !important;
            pointer-events: none !important;
          }
          
          #main-window[tabsintitlebar="true"]:not([extradragspace="true"]) #navigator-toolbox:hover #TabsToolbar {
            opacity: 1 !important;
            pointer-events: auto !important;
          }
        '';
      };
    };
  };

  # Environment variables for Wayland
  home.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_USE_XINPUT2 = "1";
  };

  # Firefox preload service for faster startup
  systemd.user.services.firefox-preload = {
    Unit = {
      Description = "Firefox preload service for faster startup";
      After = [ "graphical-session-pre.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    
    Service = {
      Type = "forking";
      ExecStart = "${pkgs-unstable.firefox}/bin/firefox --headless --profile /tmp/firefox-preload-dummy";
      ExecStop = "${pkgs.procps}/bin/pkill -f 'firefox.*headless.*preload-dummy'";
      Restart = "no";
      TimeoutStartSec = "30s";
      
      # Resource limits to minimize impact
      MemoryMax = "200M";
      CPUQuota = "10%";
    };
    
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}