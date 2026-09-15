#!/bin/bash

set -euo pipefail
brew_repository="${1:?Pass the Homebrew/brew checkout path}"
source_repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$source_repository"

# These fixtures test configuration selection, not dependency installation.
mkdir "$workdir/bin"
cat > "$workdir/bin/bundle" <<'SH'
#!/bin/sh
if [ -f Gemfile ] && grep -q '^ruby file: "\.ruby-version"$' Gemfile; then
  echo 'Ruby requirement must be migrated before updating the lockfile.' >&2
  exit 1
fi
SH
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

printf 'source "https://rubygems.org"\n\nruby file: ".ruby-version"\n\ngem "rake"\n' > "$workdir/original-gemfile"
ruby_requirement="$(sed -n '/^ruby /p' "$brew_repository/docs/Gemfile")"
printf 'source "https://rubygems.org"\n\n%s\n\ngem "rake"\n' "$ruby_requirement" > "$workdir/expected-gemfile"

for layout in root root-with-lock docs shared-docs dangling-docs first-sync-docs; do
  prepare_target "$layout"
  if [[ "$layout" == root || "$layout" == root-with-lock || "$layout" == shared-docs ]]; then
    cp "$workdir/original-gemfile" "$target/Gemfile"
  fi
  if [[ "$layout" == root-with-lock ]]; then
    touch "$target/Gemfile.lock"
  elif [[ "$layout" != root ]]; then
    mkdir "$target/docs"
    if [[ "$layout" == dangling-docs ]]; then
      ln -s ../Gemfile "$target/docs/Gemfile"
    else
      cp "$workdir/original-gemfile" "$target/docs/Gemfile"
    fi
    touch "$target/docs/Gemfile.lock"
    if [[ "$layout" == first-sync-docs ]]; then
      mv "$target/.ruby-version" "$target/docs/.ruby-version"
    fi
  fi
  commit_fixture
  sync_target
  if [[ "$layout" == docs || "$layout" == dangling-docs || "$layout" == first-sync-docs ]]; then
    if [[ -e "$target/Gemfile" ]]; then
      echo 'Docs-only sync must not create a root Gemfile.' >&2
      exit 1
    fi
    if [[ -L "$target/docs/Gemfile" ]]; then
      echo 'Docs-only Gemfile must not link to a missing root Gemfile.' >&2
      exit 1
    fi
    cmp "$brew_repository/docs/Gemfile" "$target/docs/Gemfile"
  else
    cmp "$workdir/expected-gemfile" "$target/Gemfile"
    if [[ "$layout" == shared-docs ]]; then
      test "$(readlink "$target/docs/Gemfile")" = '../Gemfile'
    fi
  fi
  if [[ "$layout" == first-sync-docs ]]; then
    if [[ "$(readlink "$target/docs/.ruby-version")" != '../.ruby-version' ]]; then
      echo 'The docs Ruby version must link to the root after the first sync.' >&2
      exit 1
    fi
  fi
  synced_head="$(git -C "$target" rev-parse HEAD)"
  sync_target
  test "$(git -C "$target" rev-parse HEAD)" = "$synced_head"
done

for repository in ruby-macho patchelf.rb; do
  prepare_target "$repository"
  cp "$workdir/original-gemfile" "$target/Gemfile"
  touch "$target/Gemfile.lock"
  commit_fixture
  sync_target
  cmp "$workdir/original-gemfile" "$target/Gemfile"
  test "$(cat "$target/.ruby-version")" = '4.0.6'
  test "$(cat "$target/.rubocop.yml")" = '# original configuration'
done

prepare_target custom-ruby-requirement
printf 'ruby ">= 3.3"\n' > "$target/Gemfile"
commit_fixture
sync_target
test "$(cat "$target/Gemfile")" = 'ruby ">= 3.3"'

prepare_target ci-orchestrator-private
commit_fixture
sync_target
test ! -e "$target/.ruby-version"
test "$(cat "$target/.rubocop.yml")" = '# original configuration'

for repository in brew homebrew-core homebrew-cask BrewUI no-template-checks
do
  prepare_target "${repository}"
  mkdir -p "${target}/.github/workflows"
  for workflow in check-issues check-prs
  do
    printf '# Custom %s workflow\n' "${workflow}" > "${target}/.github/workflows/${workflow}.yml"
  done
  commit_fixture
  sync_target
  for workflow in check-issues check-prs
  do
    if [[ "${repository}" != no-template-checks ]]
    then
      cmp "${target}/.github/workflows/${workflow}.yml" <(
        printf '%s\n' "# This file is synced from the \`.github\` repository, do not modify it directly."
        cat ".github/workflows/${workflow}.yml"
      )
    else
      test ! -e "${target}/.github/workflows/${workflow}.yml"
    fi
  done
done

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

echo 'Shared configuration checks passed.'
