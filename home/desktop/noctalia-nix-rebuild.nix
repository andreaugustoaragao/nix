{
  lib,
  writeShellApplication,
  writeText,
  python3,
  git,
  nix,
  nixos-rebuild,
  systemd,
  libnotify,
  zenity,
  repository,
  hostName,
}:
let
  settings = writeText "noctalia-nix-rebuild.json" (
    builtins.toJSON {
      inherit repository;
      hostname = hostName;
      git = lib.getExe git;
      nix = lib.getExe nix;
      rebuild = lib.getExe nixos-rebuild;
      # The NixOS setuid wrapper invokes the existing GUI auth agent. No new
      # Polkit grant or passwordless sudo rule is introduced by this helper.
      pkexec = "/run/wrappers/bin/pkexec";
      systemctl = "${systemd}/bin/systemctl";
      systemd_run = "${systemd}/bin/systemd-run";
      notify = "${libnotify}/bin/notify-send";
      zenity = lib.getExe zenity;
    }
  );
in
writeShellApplication {
  name = "noctalia-nix-rebuild";
  text = ''
    exec ${lib.getExe python3} ${./noctalia-nix-rebuild.py} --config ${settings} "$@"
  '';
}
