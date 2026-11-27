{
  lib,
  buildGoModule,
}:

buildGoModule {
  pname = "netwatch";
  version = "0.1.0";

  src = builtins.path {
    name = "netwatch-src";
    path = ./netwatch;
  };

  vendorHash = null;

  subPackages = [
    "cmd/netwatch"
  ];

  doCheck = true;

  meta = {
    description = "Zero-dependency firewall advisory, correlation, SMTP email, and heartbeat daemon (Go)";
    license = lib.licenses.mit;
    mainProgram = "netwatch";
    platforms = lib.platforms.unix;
  };
}
