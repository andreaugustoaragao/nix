{ config, pkgs, lib, inputs, ... }:

{
  # wlogout configuration (for sway)
  xdg.configFile."wlogout/layout" = {
    text = ''
      {
          "label" : "lock",
          "action" : "loginctl lock-session",
          "keybind" : "l"
      }
      {
          "label" : "logout",
          "action" : "loginctl terminate-user $USER",
          "keybind" : "e"
      }
      {
          "label" : "suspend",
          "action" : "systemctl suspend",
          "keybind" : "u"
      }
      {
          "label" : "hibernate",
          "action" : "systemctl hibernate",
          "keybind" : "h"
      }
      {
          "label" : "reboot",
          "action" : "systemctl reboot",
          "keybind" : "r"
      }
      {
          "label" : "shutdown",
          "action" : "systemctl poweroff",
          "keybind" : "s"
      }
    '';
    force = true;
  };

  xdg.configFile."wlogout/style.css" = {
    text = ''
      /* Upstream wlogout style.css (paths adjusted to Nix store) */
      * {
        background-image: none;
        box-shadow: none;
        text-shadow: none;
        border: none;
        outline: none;
        font-family: sans-serif;
      }

      window {
        background-color: rgba(46, 52, 64, 0.9);
      }

      button {
        color: #eceff4;
        background-color: rgba(59, 66, 82, 0.9);
        margin: 10px;
        padding: 20px;
        border-radius: 6px;

        background-repeat: no-repeat;
        background-position: center;
        background-size: 28%;
      }

      button:hover,
      button:focus,
      button:active {
        background-color: rgba(67, 76, 94, 0.9);
      }

      /* Icon backgrounds (same names as upstream) */
      #lock {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/lock.png"));
      }
      #logout {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/logout.png"));
      }
      #suspend {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/suspend.png"));
      }
      #hibernate {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/hibernate.png"));
      }
      #shutdown {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/shutdown.png"));
      }
      #reboot {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/reboot.png"));
      }

    '';
    force = true;
  };

  home.packages = with pkgs; [
    wlogout
  ];
}