{ agent-browser, makeWrapper }:

agent-browser.overrideAttrs (oldAttrs: {
  patches = (oldAttrs.patches or [ ]) ++ [ ./agent-browser-background.patch ];
  nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ makeWrapper ];
  postInstall = (oldAttrs.postInstall or "") + ''
    # A fresh default session avoids reusing an already-running unpatched daemon.
    wrapProgram "$out/bin/agent-browser" \
      --set-default AGENT_BROWSER_SESSION background-v1
  '';
})
