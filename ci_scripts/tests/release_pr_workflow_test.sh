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
grep -Fq 'XcodeCloudReleaseEnvironment.perform(environment: ProcessInfo.processInfo.environment)' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/ReleaseToGithub.swift"

for release_metadata_path in \
    'project.yml' \
    'ElementX.xcodeproj/project.pbxproj' \
    'JUNCHAT_CHANGES.md' \
    'ElementX/SupportingFiles/Info.plist' \
    'NSE/SupportingFiles/Info.plist' \
    'ShareExtension/SupportingFiles/Info.plist'; do
    grep -Fq -- "- \"$release_metadata_path\"" "$WORKFLOW"
done

XCODEGEN_LINE=$(grep -n -F 'xcodegen' "$WORKFLOW" | head -n1 | cut -d: -f1)
ZERO_DIFF_LINE=$(grep -n -F 'git diff --exit-code --' "$WORKFLOW" | head -n1 | cut -d: -f1)
if [[ -z "$XCODEGEN_LINE" || -z "$ZERO_DIFF_LINE" || "$XCODEGEN_LINE" -ge "$ZERO_DIFF_LINE" ]]; then
    printf '%s\n' 'Release hygiene must regenerate the Xcode project before asserting a zero diff.' >&2
    exit 98
fi

if grep -Eq 'release-to-github|upload-dsyms|fastlane|GITHUB_TOKEN|secrets\.' "$WORKFLOW"; then
    printf '%s\n' 'Release hygiene PR checks must not invoke publication, signing, or provider credentials.' >&2
    exit 96
fi

if grep -R -Eq 'gitConfigureGlobals|git[[:space:]].*config[[:space:]].*--global|"config",[[:space:]]*"--global"' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/ReleaseToGithub.swift" \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/TagNightly.swift" \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/CI.swift"; then
    printf '%s\n' 'Release tooling must not write the caller global git identity.' >&2
    exit 97
fi
