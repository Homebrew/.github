#!/bin/bash

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
check_script="$(pwd)/.github/scripts/check-licenses.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
export RUNNER_TEMP="${workdir}"
export EXPECTED_DENIED_LICENSES=AGPL-3.0-only,AGPL-1.0-or-later
mkdir -p "${workdir}/bin" "${workdir}/repository/.github"
printf '# Test policy\n\n  AGPL-3.0-only \t\nAGPL-1.0-or-later\n' >"${workdir}/repository/.github/denied-licenses.txt"

ruby -ryaml <<'RUBY'
workflow = YAML.load_file(".github/workflows/licenses.yml")
steps = workflow.fetch("jobs").fetch("licenses").fetch("steps")
check = steps.find { |step| step["name"] == "Check licences" }
abort "Workflow must run the tested script" unless check.fetch("run") == "bash .github/scripts/check-licenses.sh"
paths = workflow.fetch("on") { workflow.fetch(true) }.fetch("pull_request").fetch("paths")
abort "Missing script PR trigger" unless paths.include?(".github/scripts/check-licenses.sh")
cache = steps.find { |step| step["name"] == "Cache git-pkgs licence metadata" }.fetch("with").fetch("key")
%w[Package.swift Package.resolved].each do |filename|
  abort "Missing Swift PR trigger: #{filename}" unless paths.include?("**/#{filename}")
  abort "Missing Swift cache input: #{filename}" unless cache.include?("'**/#{filename}'")
end
RUBY

# Exercise the script without making registry requests.
cat >"${workdir}/bin/git" <<'SH'
#!/bin/bash
set -euo pipefail
arguments=" $* "
[[ "${arguments}" == *' pkgs licenses '* ]] || exit 1
[[ "${arguments}" == *' --format=json '* ]] || exit 1
[[ "${arguments}" == *" --deny=${EXPECTED_DENIED_LICENSES} "* ]] || exit 1
if [[ "${arguments}" == *' pkgs.ecosystems=swift '* ]]; then
  [[ "${arguments}" == *' --dependencies=all '* ]] || exit 1
  [[ "${arguments}" != *' pkgs.ecosystems=npm '* ]] || exit 1
  scope=swift
else
  [[ "${arguments}" == *' pkgs.ecosystems=npm '* ]] || exit 1
  [[ "${arguments}" != *' --dependencies=all '* ]] || exit 1
  scope=existing
fi
printf '%s\t%s\n' "${scope}" "${GIT_PKGS_DB}" >>"${RUNNER_TEMP}/calls"
if [[ "${scope}" != "${MOCK_FAILURE_SCOPE}" ]]; then
  printf '[]\n'
  exit 0
fi
case "${MOCK_FAILURE}" in
  denied)
    printf '%s\n' '[{"name":"transitive-package","ecosystem":"swift","version":"1.0.0","licenses":["AGPL-3.0-only"],"flagged":true,"flag_reason":"denied license"}]'
    exit 1
    ;;
  invalid)
    printf 'not JSON\n'
    ;;
  error)
    printf '[]\n'
    printf 'Metadata lookup failed\n' >&2
    exit 2
    ;;
esac
SH
chmod +x "${workdir}/bin/git"
export PATH="${workdir}/bin:${PATH}"
export MOCK_FAILURE_SCOPE=none MOCK_FAILURE=none
cd "${workdir}/repository"

bash "${check_script}" >"${workdir}/check.log" 2>&1
printf 'existing\t%s\n' "${RUNNER_TEMP}/git-pkgs/metadata.db" >"${workdir}/expected-existing"
printf 'swift\t%s\n' "${RUNNER_TEMP}/git-pkgs/swift.db" >"${workdir}/expected-swift"
cat "${workdir}/expected-existing" "${workdir}/expected-swift" >"${workdir}/expected-calls"
cmp "${workdir}/calls" "${workdir}/expected-calls"

for MOCK_FAILURE_SCOPE in existing swift; do
  export MOCK_FAILURE_SCOPE
  for MOCK_FAILURE in denied invalid error; do
    export MOCK_FAILURE
    : >"${workdir}/calls"
    status=0
    bash "${check_script}" >"${workdir}/check.log" 2>&1 || status="$?"
    if [[ "${MOCK_FAILURE}" == error ]]; then
      test "${status}" = 2
      grep -q 'Metadata lookup failed' "${workdir}/check.log"
    else
      test "${status}" = 1
    fi
    if [[ "${MOCK_FAILURE}" == denied ]]; then
      grep -q 'transitive-package' "${workdir}/check.log"
    fi
    if [[ "${MOCK_FAILURE_SCOPE}" == existing ]]; then
      cmp "${workdir}/calls" "${workdir}/expected-existing"
    else
      cmp "${workdir}/calls" "${workdir}/expected-calls"
    fi
  done
done

for policy in missing empty comments; do
  rm -f .github/denied-licenses.txt
  if [[ "${policy}" == empty ]]; then
    touch .github/denied-licenses.txt
  elif [[ "${policy}" == comments ]]; then
    printf '  # No denied licences\n\n  \t\n' >.github/denied-licenses.txt
  fi
  : >"${workdir}/calls"
  status=0
  bash "${check_script}" >"${workdir}/check.log" 2>&1 || status="$?"
  test "${status}" = 1
  test ! -s "${workdir}/calls"
  grep -q '::error::.github/denied-licenses.txt' "${workdir}/check.log"
done

echo 'License workflow checks passed.'
