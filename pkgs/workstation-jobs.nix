{
  writeShellApplication,
  python3,
  openssh,
  rsync,
  git,
  systemd,
  sccache,
  tigervnc,
  sops,
}:
let
  application =
    role: name: extraInputs:
    writeShellApplication {
      inherit name;
      runtimeInputs = [
        python3
        openssh
        rsync
        git
      ]
      ++ extraInputs;
      text = ''
        exec python3 ${../scripts/workstation-job.py} ${role} "$@"
      '';
    };
in
{
  enroll = writeShellApplication {
    name = "workstation-worker-enroll";
    runtimeInputs = [
      (python3.withPackages (ps: [ ps.pyyaml ]))
      git
      sops
    ];
    text = ''
      exec python3 ${../scripts/workstation-worker-enroll.py} "$@"
    '';
  };
  client = application "client" "workstation-job" [ ];
  desktop = writeShellApplication {
    name = "workstation-desktop";
    runtimeInputs = [
      python3
      openssh
      tigervnc
    ];
    text = ''
      exec python3 ${../scripts/workstation-desktop.py} "$@"
    '';
  };
  worker = application "worker" "workstation-worker-exec" [
    systemd
    sccache
  ];
}
