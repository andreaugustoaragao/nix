{
  lib,
  runCommand,
  writeShellScriptBin,
  python3,
  k3s,
  coreutils,
  systemd,
  qemu_kvm,
  procps,
  guestImage,
}:
let
  cleanup = runCommand "workstation-k3s-killall" { } ''
    cp ${k3s}/bin/.k3s-killall.sh-wrapped "$out"
    substituteInPlace "$out" \
      --replace-fail 'tailscale set --advertise-routes=' ': preserve existing Tailscale routes'
    chmod +x "$out"
  '';
in
writeShellScriptBin "workstation-k3s-retire" ''
  export PATH=${
    lib.makeBinPath (
      [
        coreutils
        systemd
        qemu_kvm
        procps
      ]
      ++ k3s.k3sRuntimeDeps
      ++ k3s.k3sKillallDeps
    )
  }
  unset K3S_DATA_DIR
  exec ${python3}/bin/python3 ${../scripts/workstation-k3s-retire.py} \
    --image ${guestImage}/nixos.qcow2 --cleanup ${cleanup} "$@"
''
