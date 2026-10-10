{
  lib,
  callPackage,
  python3,
  runCommand,
  writeShellApplication,
}:

let
  devBrowser = callPackage ./dev-browser.nix { };
  python = python3.withPackages (ps: [ ps.mcp ]);
  browserMcp = writeShellApplication {
    name = "dev-browser-mcp";
    text = ''
      exec ${python}/bin/python3 ${./dev-browser-mcp/server.py} \
        --command ${lib.getExe devBrowser} "$@"
    '';
    passthru.tests.protocol = runCommand "check-dev-browser-mcp" { } ''
      PYTHONDONTWRITEBYTECODE=1 ${python}/bin/python3 \
        ${./dev-browser-mcp/test_protocol.py} ${lib.getExe browserMcp}
      touch "$out"
    '';
    meta.description = "Dev Browser control over MCP for Codex sessions";
  };
in
browserMcp
