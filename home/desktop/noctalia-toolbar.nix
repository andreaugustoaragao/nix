{
  lib,
  displays,
  personalOnly,
}:
let
  dmsSession = builtins.fromJSON (builtins.readFile ./dms-session.json);
  weatherCoordinates = map builtins.fromJSON (lib.splitString "," dmsSession.weatherCoordinates);
  band = {
    capsule_band = "surface_container_high";
  };
  console = {
    start = [ ];
    center = [ "group:console" ];
    end = [ ];
  };
in
{
  bar.main = console // {
    capsule_group = [
      {
        id = "console";
        members = [
          "launcher"
          "workspaces"
          "notifications"
          "privacy"
          "tray"
          "cpu"
          "ram"
          "disk"
          "download"
          "upload"
          "herdr"
        ]
        ++ lib.optional (!personalOnly) "recorder"
        ++ [
          "nix-rebuild"
          "volume"
          "battery"
          "control-center"
          "clock"
          "session"
        ];
        fill = "surface_container";
        border = "outline_variant";
        border_width = 1.0;
        padding = 10.0;
        radius = 10.0;
        widget_spacing = 8;
      }
    ];
    monitor = {
      portrait = console // {
        match = displays.dp2;
      };
      third = console // {
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
    clock = {
      format = "{:%-I:%M %p}\n{:%a %-d %b}";
      tooltip_format = "{:%A, %-d %B %Y}";
    };
    workspaces = {
      label_source = "id";
      show_labels = true;
      show_icons = false;
      max_label_chars = 2;
      hide_when_empty = false;
      show_all_outputs = false;
    };
    active_window = {
      min_length = 180;
      max_length = 180;
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
    cpu = band // {
      type = "sysmon";
      stat = "cpu_usage";
      visualization = "none";
      label_min_width = 28;
    };
    ram = band // {
      type = "aragao/dms-toolbar:ram";
    };
    disk = band // {
      type = "aragao/dms-toolbar:disk";
    };
    volume = band;
    battery = band;
    control-center = band;
    inline-volume.type = "aragao/dms-toolbar:volume";
    recorder.type = "aragao/dms-toolbar:recorder";
    nix-rebuild.type = "aragao/nix-rebuild:rebuild";
    herdr.type = "aragao/herdr:radar";
    download = band // {
      type = "sysmon";
      stat = "net_rx";
      glyph = "arrow-down";
      visualization = "none";
      network_speed_compact = true;
      label_min_width = 32;
    };
    upload = band // {
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
    enabled = [
      "aragao/dms-toolbar"
      "aragao/nix-rebuild"
      "aragao/herdr"
    ];
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
