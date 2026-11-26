{
  lib,
  displays,
  personalOnly,
  showTemperatures ? false,
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
        ]
        ++ lib.optionals showTemperatures [
          "cpu-temp"
          "gpu-temp"
        ]
        ++ [
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
  # bar.main uses background_opacity = 0.0 around the centered console pill,
  # and attached panels inherit the host bar's background_opacity (making
  # their outer surface transparent) and anchor to the invisible full-width
  # bar edge. Keep bar panels floating (solid surface from transparency_mode)
  # at position = "auto" with open_near_click so clicking a widget opens
  # beneath it and keyboard shortcuts open centered under the bar.
  shell.panel = {
    launcher_placement = "floating";
    launcher_position = "center";
    clipboard_placement = "floating";
    clipboard_position = "auto";
    open_near_click_clipboard = true;
    control_center_placement = "floating";
    control_center_position = "auto";
    open_near_click_control_center = true;
    wallpaper_placement = "floating";
    wallpaper_position = "auto";
    open_near_click_wallpaper = true;
    session_placement = "floating";
    session_position = "auto";
    open_near_click_session = true;
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
      hide_when_empty = true;
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
    cpu-temp = band // {
      type = "sysmon";
      stat = "cpu_temp";
      visualization = "none";
      label_min_width = 30;
    };
    gpu-temp = band // {
      type = "sysmon";
      stat = "gpu_temp";
      glyph = "gpu-usage";
      visualization = "none";
      label_min_width = 30;
    };
    ram = band // {
      type = "aragao/dms-toolbar:ram";
      actions.left = "panel-toggle control-center system";
    };
    disk = band // {
      type = "aragao/dms-toolbar:disk";
      actions.left = "panel-toggle control-center system";
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
    enabled = false;
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
