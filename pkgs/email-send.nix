{
  lib,
  buildGoModule,
  makeWrapper,
  browser-task,
}:

buildGoModule {
  pname = "email-send";
  version = "0.1.0";

  src = builtins.path {
    name = "email-send-src";
    path = ./email-send;
  };

  vendorHash = null;

  subPackages = [
    "cmd/email-send"
  ];

  nativeBuildInputs = [ makeWrapper ];

  doCheck = true;

  postInstall = ''
    wrapProgram "$out/bin/email-send" \
      --prefix PATH : "${lib.makeBinPath [ browser-task ]}"
  '';

  meta = {
    description = "Deterministic, task-owned Gmail sender CLI with multi-attachment support (Go)";
    mainProgram = "email-send";
    platforms = lib.platforms.unix;
  };
}
