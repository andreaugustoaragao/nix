set -euo pipefail

git_command=${NOTES_SYNC_GIT:?NOTES_SYNC_GIT must identify the managed Git executable}

refuse() {
  printf '%s\n' "$1" >&2
  exit 1
}

for state_dir in .fulcrum .fulcrum/shared-runtime; do
  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    [[ -d "$state_dir" && ! -L "$state_dir" && -r "$state_dir" && -x "$state_dir" ]] \
      || refuse 'Notes sync paused: the cutover marker directory cannot be inspected safely.'
  fi
done
for marker in .fulcrum/shared-runtime/cutover.json .fulcrum/shared-runtime/cutover.json.partial; do
  [[ ! -e "$marker" && ! -L "$marker" ]] || refuse 'Notes sync paused: shared vault cutover requires reconciliation.'
done

repository=$("$git_command" rev-parse --show-toplevel 2>/dev/null) || refuse 'Notes sync requires an existing Git worktree.'
[[ "$repository" == "$(pwd -P)" ]] || refuse 'Notes sync must run at the notes repository root.'
branch=$("$git_command" symbolic-ref --quiet --short HEAD) || refuse 'Notes sync cannot run on a detached HEAD.'
[[ "$branch" == main ]] || refuse 'Notes sync requires the main branch; the current branch was preserved.'
"$git_command" rev-parse --verify HEAD >/dev/null 2>&1 || refuse 'Notes sync requires an existing initial commit.'
"$git_command" remote get-url origin >/dev/null 2>&1 || refuse 'Notes sync requires the configured origin remote.'

for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
  state_path=$("$git_command" rev-parse --git-path "$state")
  [[ ! -e "$state_path" ]] || refuse 'Notes sync paused: finish the existing Git operation before retrying.'
done
[[ -z "$("$git_command" ls-files --unmerged)" ]] || refuse 'Notes sync paused: unresolved files and their index versions were preserved.'

if [[ "${1:-}" == --check && "$#" == 1 ]]; then
  exit 0
fi
[[ "$#" == 0 ]] || refuse 'Usage: notes-sync-reconcile [--check]'

"$git_command" fetch origin refs/heads/main:refs/remotes/origin/main
"$git_command" add --all
if ! "$git_command" diff --cached --quiet; then
  "$git_command" commit -m "Auto-sync notes: $(date '+%Y-%m-%d %H:%M:%S')"
fi

if ! "$git_command" merge-base --is-ancestor origin/main HEAD; then
  if ! "$git_command" merge origin/main --no-edit; then
    refuse 'Notes sync stopped: the merge failed. Local and remote versions were preserved for resolution; nothing was pushed.'
  fi
fi

if [[ "$("$git_command" rev-parse HEAD)" != "$("$git_command" rev-parse origin/main)" ]]; then
  "$git_command" push origin main
fi
printf '%s\n' 'Notes sync completed successfully.'
