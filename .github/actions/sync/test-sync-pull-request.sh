#!/bin/bash

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
export SYNC_TEST_LOG="$workdir/commands"
export GH_REPO=Homebrew/brew JOB_INDEX=0
mkdir -p "$workdir/bin" "$workdir/target/$GH_REPO"

ruby -ryaml > "$workdir/sync.sh" <<'RUBY'
steps = YAML.load_file(".github/workflows/sync-shared-config.yml").fetch("jobs").fetch("sync").fetch("steps")
step = steps.find { |item| item.fetch("env", {}).key?("JOB_INDEX") }
unless step.fetch("if") == "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
  abort "Sync PR reconciliation must run even when detection reports no changes."
end
unless step.fetch("env").fetch("HAS_CHANGES") == "${{ steps.detect_changes.outputs.pull_request }}"
  abort "Sync PR reconciliation must receive the change detection result."
end
puts step.fetch("run")
RUBY

# Keep all Git and GitHub operations local to these fixtures.
cat > "$workdir/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
case "$*" in
  api\ *)
    if [[ "$OPEN_PR" == true ]]; then
      printf '[{"number":1}]\n'
    else
      printf '[]\n'
    fi
    ;;
  'pr close sync-shared-config --delete-branch')
    echo close >> "$SYNC_TEST_LOG"
    ;;
  'pr create --head sync-shared-config '*)
    echo create >> "$SYNC_TEST_LOG"
    ;;
  *) exit 1 ;;
esac
SH
cat > "$workdir/bin/git" <<'SH'
#!/bin/bash
set -euo pipefail
case "$1" in
  checkout) ;;
  fetch|push) echo "$1" >> "$SYNC_TEST_LOG" ;;
  diff) [[ "$BRANCH_DIFFERS" != true ]] ;;
  *) exit 1 ;;
esac
SH
chmod +x "$workdir/bin/gh" "$workdir/bin/git"
export PATH="$workdir/bin:$PATH"
cd "$workdir"

check_sync() {
  export HAS_CHANGES="$1" OPEN_PR="$2" BRANCH_DIFFERS="$3"
  : > "$SYNC_TEST_LOG"
  bash -euo pipefail sync.sh
  if [[ "$(cat "$SYNC_TEST_LOG")" != "$4" ]]; then
    cat "$SYNC_TEST_LOG" >&2
    echo "Unexpected sync PR actions for changes=$1, open=$2, differs=$3" >&2
    return 1
  fi
}

# An empty output is how detection reports no changes.
check_sync '' true true close
check_sync '' false false ''
check_sync true false false $'push\ncreate'
check_sync true true true $'fetch\npush'
check_sync true true false fetch

echo 'Sync pull request checks passed.'
