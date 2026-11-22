{
  lib,
  buildGoModule,
  makeWrapper,
  nodejs,
  browser-task,
  workerExtension ? null,
}:

buildGoModule {
  pname = "chat-send";
  version = "0.2.0";

  src = builtins.path {
    name = "chat-send-src";
    path = ./chat-send;
  };

  vendorHash = null;

  subPackages = [
    "cmd/chat-send"
    "cmd/chat-send-task"
  ];

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ nodejs ];

  doCheck = true;

  postInstall = ''
    wrapProgram "$out/bin/chat-send" \
      --prefix PATH : "${lib.makeBinPath [ browser-task ]}"
    wrapProgram "$out/bin/chat-send-task" \
      --set-default CHAT_SEND_BIN "$out/bin/chat-send" ${
        lib.optionalString (
          workerExtension != null
        ) ''--set-default CHAT_SEND_WORKER_EXTENSION "${workerExtension}"''
      }
  '';

  meta = {
    description = "Private, task-owned Google Chat sender and worker CLI (Go)";
    mainProgram = "chat-send";
    platforms = lib.platforms.unix;
  };
}
