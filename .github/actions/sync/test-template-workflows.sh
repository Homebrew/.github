#!/bin/bash

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
export RUNNER_TEMP="${workdir}"
export GITHUB_OUTPUT="${workdir}/output"
export ISSUE_NUMBER=7 PR_NUMBER=8
mkdir -p "${workdir}/bin" "${workdir}/check-issues/templates" "${workdir}/check-prs"
cp .github/scripts/check_template.rb "${workdir}/check_template.rb"

# Every GitHub request is handled locally, including comment deletion.
cat >"${workdir}/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "$1" == api ]]
case "$2" in
  --paginate)
    cat "${RUNNER_TEMP}/comments"
    ;;
  --method)
    [[ "$3" == DELETE ]]
    printf '%s\n' "$4" >>"${RUNNER_TEMP}/deleted"
    awk -v id="${4##*/}" '$0 != id' "${RUNNER_TEMP}/comments" >"${RUNNER_TEMP}/remaining"
    mv "${RUNNER_TEMP}/remaining" "${RUNNER_TEMP}/comments"
    ;;
  repos/*/contents/.github/ISSUE_TEMPLATE?ref=main)
    printf '%s\n' .github/ISSUE_TEMPLATE/bug.yml
    ;;
  repos/*/contents/.github/ISSUE_TEMPLATE/bug.yml?ref=main)
    repository="${2#repos/}"
    printf 'body:\n- type: textarea\n  attributes:\n    label: %s details\n' "${repository%%/contents/*}" | base64
    ;;
  *)
    printf 'Unexpected GitHub request: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "${workdir}/bin/gh"
export PATH="${workdir}/bin:${PATH}"
gh_path="$(command -v gh)"
[[ "${gh_path}" == "${workdir}/bin/gh" ]]

run_step() {
  : >"${GITHUB_OUTPUT}"
  ruby -ryaml - ".github/workflows/${1}.yml" "$2" <<'RUBY'
steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("manage").fetch("steps")
step = steps.find { |item| item["name"] == ARGV.fetch(1) }
abort "Missing step: #{ARGV.fetch(1)}" unless step
env = step.fetch("env", {}).transform_values do |value|
  abort "Unexpected environment binding: #{value}" unless value == "${{ github.event.issue.title }}"

  ENV.fetch("MOCK_ISSUE_TITLE")
end
exit(system(env, "bash", "-euo", "pipefail", "-c", step.fetch("run")) ? 0 : 1)
RUBY
}

assert_issue() {
  export MOCK_ISSUE_TITLE="$1"
  printf '%s\n' "$2" >"${workdir}/check-issues/body"
  run_step check-issues 'Check issue template'
  cmp "${GITHUB_OUTPUT}" <(printf 'complete_template=%s\n' "$3")
}

crash_report=$'<summary>Automatic crash report</summary>\nHomebrew.app crash report'
for repository in BrewUI brew homebrew-core homebrew-cask
do
  export GITHUB_REPOSITORY="Homebrew/${repository}"
  printf 'Checking templates and crash reports for %s\n' "${GITHUB_REPOSITORY}"
  rm -f "${workdir}/check-issues/templates/"*.yml
  run_step check-issues 'Fetch issue templates'
  templates=("${workdir}/check-issues/templates/"*.yml)
  if [[ "${repository}" == BrewUI ]]
  then
    [[ "${#templates[@]}" == 1 ]]
    test -f "${workdir}/check-issues/templates/Homebrew-BrewUI-bug.yml"
    assert_issue 'Crash: Homebrew.app' "${crash_report}" true
    assert_issue 'Ordinary issue' "${crash_report}" false
    assert_issue 'Crash: Homebrew.app' '<summary>Automatic crash report</summary>' false
    assert_issue 'Crash: Homebrew.app' 'Homebrew.app crash report' false
    assert_issue 'Ordinary issue' 'Homebrew/brew details' false
  else
    [[ "${#templates[@]}" == 3 ]]
    for sibling in brew homebrew-core homebrew-cask
    do
      test -f "${workdir}/check-issues/templates/Homebrew-${sibling}-bug.yml"
      assert_issue 'Transferred issue' "Homebrew/${sibling} details" true
    done
    assert_issue 'Crash: Homebrew.app' "${crash_report}" false
    assert_issue 'Ordinary issue' 'Homebrew/BrewUI details' false
  fi
  assert_issue 'Ordinary issue' "${GITHUB_REPOSITORY} details" true
  assert_issue 'Ordinary issue' 'Incomplete body' false

  for workflow in check-issues check-prs
  do
    printf 'Checking resolved comments for %s/%s\n' "${GITHUB_REPOSITORY}" "${workflow}"
    printf '101\n102\n' >"${workdir}/comments"
    : >"${workdir}/deleted"
    run_step "${workflow}" 'Find incomplete template comment'
    cmp "${GITHUB_OUTPUT}" <(printf 'has_incomplete_template_comment=true\n')
    run_step "${workflow}" 'Remove resolved template comments'
    cmp "${workdir}/deleted" <(
      printf 'repos/%s/issues/comments/%s\n' "${GITHUB_REPOSITORY}" 101 "${GITHUB_REPOSITORY}" 102
    )
    test ! -s "${workdir}/comments"
    run_step "${workflow}" 'Find incomplete template comment'
    cmp "${GITHUB_OUTPUT}" <(printf 'has_incomplete_template_comment=false\n')
  done
done

# GitHub evaluates these conditions before executing the tested shell steps.
ruby -rjson -ryaml <<'RUBY'
%w[check-issues check-prs].each do |workflow|
  job = YAML.load_file(".github/workflows/#{workflow}.yml").fetch("jobs").fetch("manage")
  repositories = JSON.parse(job.fetch("if").match(/fromJSON\('([^']+)'\)/)[1])
  abort "#{workflow} excludes BrewUI" unless repositories.include?("Homebrew/BrewUI")
  steps = job.fetch("steps")
  comments = steps.find { |step| step["id"] == "comments" }
  abort "#{workflow} skips comment cleanup for open, complete submissions" if comments.key?("if")
  cleanup = steps.find { |step| step["name"] == "Remove resolved template comments" }
  unless cleanup.fetch("if").split.join(" ") ==
         "steps.template.outputs.complete_template == 'true' && steps.comments.outputs.has_incomplete_template_comment == 'true'"
    abort "#{workflow} removes unresolved comments"
  end
  unless steps.index(cleanup) > steps.index { |step| step["name"].start_with?("Reopen completed") }
    abort "#{workflow} removes the marker before reopening"
  end
end
RUBY

echo 'Template workflow checks passed.'
