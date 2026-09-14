#!/bin/bash

set -euo pipefail
brew_repository="${1:?Pass the Homebrew/brew checkout path}"
source_repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$source_repository"

# These fixtures test configuration selection, not dependency installation.
mkdir "$workdir/bin"
printf '#!/bin/sh\nexit 0\n' > "$workdir/bin/bundle"
chmod +x "$workdir/bin/bundle"
export PATH="$workdir/bin:$PATH"

prepare_target() {
  target="$workdir/$1"
  mkdir -p "$target"
  printf '4.0.6\n' > "$target/.ruby-version"
  printf '# original configuration\n' > "$target/.rubocop.yml"
  git -C "$target" init --quiet
  git -C "$target" config user.name Test
  git -C "$target" config user.email test@example.invalid
  git -C "$target" config commit.gpgsign false
  git -C "$target" config core.hooksPath /dev/null
}

commit_fixture() {
  git -C "$target" add --all
  git -C "$target" commit --quiet --message Fixture
}

sync_target() {
  if ! ruby .github/actions/sync/shared-config.rb "$target" "$brew_repository" > "$workdir/sync.log" 2>&1; then
    cat "$workdir/sync.log" >&2
    return 1
  fi
}

assert_no_ruby_config() {
  test ! -e "$target/.ruby-version"
  test ! -e "$target/.rubocop.yml"
}

prepare_target no-ruby
commit_fixture
sync_target
assert_no_ruby_config
sync_target
assert_no_ruby_config

case_index=0
for filename in 'lib/example.rb' 'types/example.rbi' 'tasks/example.rake' 'example.gemspec' \
                'Gemfile' 'nested/Gemfile' 'Gemfile.lock' 'Rakefile' $'lib/with\nnewline.rb'; do
  case_index=$((case_index + 1))
  prepare_target "ruby-$case_index"
  mkdir -p "$target/$(dirname "$filename")"
  touch "$target/$filename"
  rm "$target/.ruby-version" "$target/.rubocop.yml"
  commit_fixture
  sync_target
  test -s "$target/.ruby-version"
  test -s "$target/.rubocop.yml"
done

prepare_target untracked-ruby
commit_fixture
touch "$target/untracked.rb"
sync_target
assert_no_ruby_config

prepare_target ruby-macho
commit_fixture
sync_target
test "$(cat "$target/.ruby-version")" = '4.0.6'
test "$(cat "$target/.rubocop.yml")" = '# original configuration'

prepare_target ci-orchestrator-private
commit_fixture
sync_target
test ! -e "$target/.ruby-version"
test "$(cat "$target/.rubocop.yml")" = '# original configuration'

target="$workdir/not-a-repository"
mkdir "$target"
printf 'keep\n' > "$target/.ruby-version"
printf 'keep\n' > "$target/.rubocop.yml"
if ruby .github/actions/sync/shared-config.rb "$target" "$brew_repository" > "$workdir/sync.log" 2>&1; then
  echo 'Expected Git inspection to fail outside a repository.' >&2
  exit 1
fi
test "$(cat "$target/.ruby-version")" = keep
test "$(cat "$target/.rubocop.yml")" = keep

echo 'Shared Ruby configuration checks passed.'
