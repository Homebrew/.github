#!/bin/bash

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
export SYNC_TEST_LOG="$workdir/commands"
export GH_REPO=Homebrew/brew
mkdir -p "$workdir/bin" "$workdir/target/$GH_REPO"

ruby -ryaml > "$workdir/sync.sh" <<'RUBY'
steps = YAML.load_file(".github/workflows/sync-shared-config.yml").fetch("jobs").fetch("sync").fetch("steps")
step = steps.find { |item| item.fetch("env", {}).key?("HAS_CHANGES") }
unless step.fetch("if") == "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
  abort "Sync PR reconciliation must run even when detection reports no changes."
end
unless step.fetch("env").fetch("HAS_CHANGES") == "${{ steps.detect_changes.outputs.pull_request }}"
  abort "Sync PR reconciliation must receive the change detection result."
end
open_pr = steps.find { |item| item["name"] == "Open sync pull request" }
unless open_pr.fetch("if").include?("steps.detect_changes.outputs.pull_request == 'true' && steps.pr.outputs.number == ''")
  abort "Only open a PR for changes without an existing PR."
end
puts step.fetch("run")
RUBY

# Keep all Git and GitHub operations local to these fixtures.
cat > "$workdir/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
case "$*" in
  'pr close 1 --delete-branch')
    echo close >> "$SYNC_TEST_LOG"
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
  export HAS_CHANGES="$1" PR="$2" BRANCH_DIFFERS="$3"
  : > "$SYNC_TEST_LOG"
  (cd "target/$GH_REPO" && bash -euo pipefail "$workdir/sync.sh")
  if [[ "$(cat "$SYNC_TEST_LOG")" != "$4" ]]; then
    cat "$SYNC_TEST_LOG" >&2
    echo "Unexpected sync PR actions for changes=$1, open=$2, differs=$3" >&2
    return 1
  fi
}

# An empty output is how detection reports no changes.
check_sync '' 1 true close
check_sync '' '' false ''
check_sync true '' false push
check_sync true 1 true $'fetch\npush'
check_sync true 1 false fetch

echo 'Sync pull request checks passed.'
