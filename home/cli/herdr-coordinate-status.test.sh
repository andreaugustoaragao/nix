#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --events ]]; then
  status_bin="$2"
  export HC_TERMINAL_ID=status-fixture
  export HERDR_COORDINATE_STATE_DIR="$3"
  export HERDR_COORDINATE_TTY
  HERDR_COORDINATE_TTY=$(tty)
  printf '%s\n' '{"hook_event_name":"beforeSubmitPrompt"}' | "$status_bin"
  "$status_bin" blocked question
  printf '%s\n' '{"hook_event_name":"stop","status":"completed"}' | "$status_bin"
  test -f "$HERDR_COORDINATE_STATE_DIR/blocked"
  printf '%s\n' '{"hook_event_name":"beforeSubmitPrompt"}' | "$status_bin"
  test ! -e "$HERDR_COORDINATE_STATE_DIR/blocked"
  printf '%s\n' '{"hook_event_name":"stop","status":"completed"}' | "$status_bin"
  printf '%s\n' '{"hook_event_name":"stop","status":"aborted"}' | "$status_bin"
  printf '%s\n' '{"hook_event_name":"stop","status":"error"}' | "$status_bin"
  printf '%s\n' 'malformed' | "$status_bin"
  printf '%s\n' '{"hook_event_name":"unrelated"}' | "$status_bin"
  env -u HC_TERMINAL_ID "$status_bin" done
  env HERDR_COORDINATE_TTY="$HERDR_COORDINATE_STATE_DIR/not-a-tty" "$status_bin" done
  test ! -e "$HERDR_COORDINATE_STATE_DIR/not-a-tty"
  if "$status_bin" blocked invalid; then exit 1; fi
  "$status_bin" clear
  exit 0
fi

# Linux PTY integration test; pass the built herdr-cursor-status executable.
status_bin="${1:?Usage: herdr-coordinate-status.test.sh /path/to/herdr-cursor-status}"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
script -q -e "$test_dir/terminal.log" -- bash "$0" --events "$status_bin" "$test_dir" >/dev/null
rg --text --only-matching 'state=[a-z]+:app=cursor-agent(:kind=[a-z]+)?' \
  "$test_dir/terminal.log" > "$test_dir/actual"
cat > "$test_dir/expected" <<'EOF'
state=working:app=cursor-agent
state=blocked:app=cursor-agent:kind=question
state=blocked:app=cursor-agent:kind=question
state=working:app=cursor-agent
state=done:app=cursor-agent
state=idle:app=cursor-agent
state=error:app=cursor-agent
state=clear:app=cursor-agent
EOF
diff -u "$test_dir/expected" "$test_dir/actual"
printf 'PASS: lifecycle, persistent questions, resumption and invalid-input handling\n'
