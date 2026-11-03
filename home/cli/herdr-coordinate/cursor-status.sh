if [[ -z "${HC_TERMINAL_ID:-}" || -z "${HERDR_COORDINATE_TTY:-}" || ! -c "$HERDR_COORDINATE_TTY" ]]; then
  printf '{}\n'
  exit 0
fi

kind=""
case "${1:-hook}" in
  hook)
    state=$(jq -r '
      if .hook_event_name == "beforeSubmitPrompt" then "working"
      elif .hook_event_name == "stop" then
        if .status == "completed" then "done"
        elif .status == "aborted" then "idle"
        elif .status == "error" then "error"
        else empty end
      else empty end
    ' 2>/dev/null) || state=""
    ;;
  working|done|idle|error|clear) state="$1" ;;
  blocked)
    state=blocked
    case "${2:-question}" in
      question|permission|auth) kind=":kind=${2:-question}" ;;
      *) printf '{}\n'; exit 1 ;;
    esac
    ;;
  *) printf '{}\n'; exit 1 ;;
esac

if [[ -n "$state" ]]; then
  printf '\033]7501;state=%s:app=cursor-agent%s\033\\' "$state" "$kind" > "$HERDR_COORDINATE_TTY"
fi
printf '{}\n'
