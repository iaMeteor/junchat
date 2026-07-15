#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
WORKFLOW="$REPOSITORY_ROOT/.github/workflows/release-hygiene.yml"

if [[ ! -f "$WORKFLOW" ]]; then
    printf '%s\n' 'Release hygiene tests are not wired into a PR workflow.' >&2
    exit 95
fi

grep -Fq 'pull_request:' "$WORKFLOW"
grep -Fq 'permissions: {}' "$WORKFLOW"
grep -Fq 'run: swift test' "$WORKFLOW"
grep -Fq 'for test_script in ci_scripts/tests/*_test.sh' "$WORKFLOW"

if grep -Eq 'release-to-github|upload-dsyms|fastlane|GITHUB_TOKEN|secrets\.' "$WORKFLOW"; then
    printf '%s\n' 'Release hygiene PR checks must not invoke publication, signing, or provider credentials.' >&2
    exit 96
fi
