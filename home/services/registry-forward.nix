{ pkgs, ... }:

{
  # Existing build commands keep pushing to localhost:5000. Registry data
  # lives on prl-k8s-vm; this unprivileged socket only forwards TCP traffic.
  systemd.user.sockets.registry-forward = {
    Unit.Description = "Local endpoint for the Kubernetes VM registry";
    Socket.ListenStream = [
      "127.0.0.1:5000"
      "[::1]:5000"
    ];
    Install.WantedBy = [ "sockets.target" ];
  };
  systemd.user.services.registry-forward = {
    Unit.Description = "Forward the local registry endpoint to prl-k8s-vm";
    Service = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 10.211.55.5:5000";
      NoNewPrivileges = true;
      Restart = "on-failure";
    };
  };
}
