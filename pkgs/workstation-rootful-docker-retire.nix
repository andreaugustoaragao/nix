{
  writeShellApplication,
  docker_29,
  systemd,
  coreutils,
  inetutils,
}:
writeShellApplication {
  name = "workstation-rootful-docker-retire";
  runtimeInputs = [
    docker_29
    systemd
    coreutils
    inetutils
  ];
  text = ''
    if [[ "$EUID" -ne 0 || "$(hostname)" != workstation ]]; then
      echo 'Run with GUI authentication on workstation.' >&2
      exit 1
    fi
    systemctl stop docker-lazy.service
    if [[ -S /run/docker.sock ]]; then
      test "$(stat -c %u /run/docker.sock)" = 0
      containers=$(docker -H unix:///run/docker.sock ps --all --quiet)
      if [[ -n "$containers" ]]; then
        readarray -t ids <<< "$containers"
        docker -H unix:///run/docker.sock update --restart=no "''${ids[@]}" >/dev/null
        docker -H unix:///run/docker.sock stop --timeout 30 "''${ids[@]}"
      fi
      test -z "$(docker -H unix:///run/docker.sock ps --quiet)"
    fi
    systemctl stop docker.socket docker.service
    test "$(systemctl show docker.service -p MainPID --value)" = 0
    echo 'Rootful containers and daemon stopped; existing data retained offline.'
  '';
}
