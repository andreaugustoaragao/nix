# Minimal Pi sessions; task-specific arguments can select a model, prompt, or tools.
case "${1:-}" in
  install|remove|uninstall|update|list|config|auth|mcp|--help|-h|--version|-v|--list-models)
    exec @pi@ "$@"
    ;;
esac

pi_task_model=@local-model@
pi_task_model_explicit=false
pi_task_value_pending=false
pi_task_model_pending=false
for pi_task_argument in "$@"; do
  if [[ "$pi_task_value_pending" == true ]]; then
    if [[ "$pi_task_model_pending" == true ]]; then
      if [[ -n "$pi_task_argument" && "$pi_task_argument" != -* ]]; then
        pi_task_model_explicit=true
      fi
      pi_task_model_pending=false
    fi
    pi_task_value_pending=false
    continue
  fi
  case "$pi_task_argument" in
    --) break ;;
    --model)
      pi_task_model_explicit=false
      pi_task_model_pending=true
      pi_task_value_pending=true
      ;;
    --provider|--api-key|--system-prompt|--append-system-prompt|--name|-n|\
    --session|--session-id|--fork|--session-dir|--models|--tools|-t|\
    --exclude-tools|-xt|--thinking|--export|--extension|-e|--skill|\
    --prompt-template|--theme|--use-theme|--mode|--tui-mode)
      pi_task_value_pending=true
      ;;
  esac
done

if [[ -z "$pi_task_model" ]] && [[ "$pi_task_model_explicit" == false ]]; then
  printf '%s\n' 'Pi has no local model configured on this host. Select one explicitly with --model provider/model.' >&2
  exit 2
fi

pi_task_defaults=(
  --no-context-files --no-skills --no-prompt-templates
  --no-extensions --no-mcp --no-tools --offline
  --thinking low
  --system-prompt 'Complete only the specific task in the supplied brief. Use only supplied facts and explicitly enabled tools. Ask for essential missing input. Keep the result concise and state uncertainty.'
)
if [[ -n "$pi_task_model" ]]; then
  pi_task_defaults+=(--model "$pi_task_model" --models 'llama-cpp/*-local')
fi

exec @pi@ "${pi_task_defaults[@]}" "$@"
