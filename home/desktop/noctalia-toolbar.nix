{
  lib,
  displays,
  personalOnly,
}:
let
  dmsSession = builtins.fromJSON (builtins.readFile ./dms-session.json);
  weatherCoordinates = map builtins.fromJSON (lib.splitString "," dmsSession.weatherCoordinates);
  secondary = {
    start = [
      "clock"
      "workspaces"
      "active_window"
    ];
    center = [ ];
    end = [
      "clipboard"
      "notifications"
      "control-center"
      "download"
      "upload"
      "bluetooth"
      "privacy"
      "tray"
    ];
  };
in
{
  bar.main = {
    start = [
      "clock"
      "weather"
      "workspaces"
      "active_window"
      "media"
    ];
    center = [ ];
    end = [
      "clipboard"
      "cpu"
      "ram"
      "disk"
      "notifications"
      "battery"
      "inline-volume"
      "control-center"
      "bluetooth"
      "caffeine"
    ]
    ++ lib.optional (!personalOnly) "recorder"
    ++ [
      "download"
      "upload"
      "privacy"
      "tray"
    ];
    monitor = {
      portrait = secondary // {
        match = displays.dp2;
      };
      third = secondary // {
        match = "Virtual-3";
      };
    };
  };
  shell.panel = {
    launcher_placement = "floating";
    launcher_position = "center";
    clipboard_placement = "attached";
    clipboard_position = "top_right";
    control_center_position = "top_right";
    wallpaper_position = "top_left";
    session_position = "top_right";
  };
  notification.position = "top_center";
  widget = {
    clock.format = "{:%a %-d %b} {:%-I:%M %p}";
    workspaces = {
      label_source = "id";
      show_labels = true;
      show_icons = false;
      max_label_chars = 2;
      hide_when_empty = false;
      show_all_outputs = false;
    };
    active_window = {
      min_length = 40;
      max_length = 120;
    };
    media = {
      min_length = 40;
      max_length = 100;
      hide_when_no_media = true;
      title_scroll = "none";
      actions = {
        scroll_up = "volume-up";
        scroll_down = "volume-down";
      };
    };
    weather = {
      show_condition = false;
      max_length = 70;
    };
    cpu = {
      type = "sysmon";
      stat = "cpu_usage";
      visualization = "none";
      label_min_width = 28;
    };
    ram.type = "aragao/dms-toolbar:ram";
    disk.type = "aragao/dms-toolbar:disk";
    inline-volume.type = "aragao/dms-toolbar:volume";
    recorder.type = "aragao/dms-toolbar:recorder";
    download = {
      type = "sysmon";
      stat = "net_rx";
      glyph = "arrow-down";
      visualization = "none";
      network_speed_compact = true;
      label_min_width = 32;
    };
    upload = {
      type = "sysmon";
      stat = "net_tx";
      glyph = "arrow-up";
      visualization = "none";
      network_speed_compact = true;
      label_min_width = 32;
    };
    network = {
      show_label = false;
      vpn_status = "both";
    };
    bluetooth.hide_when_adapter_off = true;
    privacy.hide_inactive = true;
  };
  system.monitor.enabled = true;
  weather = {
    enabled = true;
    unit = "celsius";
    effects = false;
  };
  location = {
    auto_locate = false;
    latitude = builtins.elemAt weatherCoordinates 0;
    longitude = builtins.elemAt weatherCoordinates 1;
  };
  plugins = {
    enabled = [ "aragao/dms-toolbar" ];
    auto_update = "none";
    source = [
      {
        name = "local-toolbar";
        kind = "path";
        location = toString (
          builtins.path {
            name = "noctalia-toolbar-plugins";
            path = ./noctalia-plugins;
          }
        );
        enabled = true;
      }
    ];
  };
}
