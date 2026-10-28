{
  lib,
  callPackage,
  writeShellApplication,
}:

let
  browserTask = callPackage ./browser-task.nix { };
  browserMcp = writeShellApplication {
    name = "dev-browser-mcp";
    text = ''
      exec ${lib.getExe browserTask} "$@" mcp
    '';
    passthru.tests = browserTask.tests;
    meta.description = "Native browser-task MCP server";
  };
in
browserMcp
