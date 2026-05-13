{
  pkgs,
  ...
}:

{
  # Wrapper for the `pi` coding agent (from @mariozechner/pi-coding-agent,
  # installed via npm at ~/.npm-global/bin/pi) preset to Anthropic's
  # Claude Opus 4.7 with the xhigh adaptive-thinking effort. Extra args
  # are forwarded so you can pass `@file` references or an inline prompt.
  home.packages = [
    (pkgs.writeShellScriptBin "pi-opus" ''
      exec pi --provider anthropic --model claude-opus-4-7 --thinking xhigh "$@"
    '')
  ];
}
