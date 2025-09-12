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
    
    # Privacy-focused preferences
    preferences = {
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
    };
    
    profiles = {
      default = {
        id = 0;
        name = "default";
        isDefault = true;
        
        extensions = with pkgs.nur.repos.rycee.firefox-addons; [
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
        };
      };
    };
  };

  # Environment variables for Wayland
  home.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_USE_XINPUT2 = "1";
  };
}