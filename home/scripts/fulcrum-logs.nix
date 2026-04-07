{
  pkgs,
  ...
}:

{
  home.packages = [
    (pkgs.writeShellScriptBin "fulcrum_logs" ''
      JQ_FILTER='
        def color:
          if .level == "error" then "\u001b[31m"
          elif .level == "warn" then "\u001b[33m"
          elif .level == "debug" then "\u001b[36m"
          else "\u001b[32m" end;
        color + "\(.ts | split(".")[0] + "Z" | fromdate | localtime | strftime("%H:%M:%S")) \(.level | ascii_upcase | .[0:4]) \(.logger | split(".") | last) \u001b[1m\(.msg)\u001b[0m" +
        (to_entries | map(select(.key | IN("ts","level","msg","logger","service.name","service.version","trace_id","span_id") | not)) | if length > 0 then " \u001b[90m" +
      (map("\(.key)=\(.value)") | join(" ")) + "\u001b[0m" else "" end)'

      trap 'exit 0' INT TERM

      export TZ=America/Denver

      while true; do
        ${pkgs.docker}/bin/docker logs -f fulcrum 2>&1 | ${pkgs.jq}/bin/jq -Rr "try (fromjson | $JQ_FILTER) catch ."
        printf '\u001b[33m%s Fulcrum stopped, waiting for restart...\u001b[0m\n' "$(date +%H:%M:%S)"
        while ! ${pkgs.docker}/bin/docker inspect -f '{{.State.Running}}' fulcrum 2>/dev/null | grep -q true; do
          sleep 2
        done
        printf '\u001b[32m%s Fulcrum restarted, resuming logs\u001b[0m\n' "$(date +%H:%M:%S)"
      done
    '')
  ];
}
