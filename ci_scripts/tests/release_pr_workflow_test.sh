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
if ! grep -Fq 'expectedWorkflow: .release' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/ReleaseToGithub.swift"; then
    printf '%s\n' 'release-to-github lacks exact Release command authorization.' >&2
    exit 104
fi
grep -Fq 'pushAfterRevalidatingDraft' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/ReleaseToGithub.swift"
grep -Fq 'JunchatReleasePreflight.validateCurrentRepositoryFiles()' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/ReleaseToGithub.swift"
grep -Fq 'revalidateReleaseArtifacts(validateProjectMetadata: true)' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/ReleaseToGithub.swift"
if ! grep -Fq 'expectedWorkflow: .nightly' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/TagNightly.swift"; then
    printf '%s\n' 'tag-nightly lacks exact Nightly command authorization.' >&2
    exit 102
fi
if ! grep -Fq 'allowedWorkflows: [.release, .nightly]' \
    "$REPOSITORY_ROOT/Tools/Sources/Commands/CI/UploadDSYMs.swift"; then
    printf '%s\n' 'upload-dsyms lacks Release-or-Nightly command authorization.' >&2
    exit 103
fi

PREFLIGHT_COMMAND="$REPOSITORY_ROOT/Tools/Sources/Commands/CI/ValidateJunchatReleasePreflight.swift"
if grep -Eq 'codesignExecutablePath|otoolExecutablePath|dwarfdumpExecutablePath' "$PREFLIGHT_COMMAND"; then
    printf '%s\n' 'The production preflight command exposes an artifact verifier override.' >&2
    exit 101
fi
ARTIFACT_VALIDATOR="$REPOSITORY_ROOT/Tools/Sources/JunchatReleaseArtifacts.swift"
grep -Fq 'static func production() -> Self' "$ARTIFACT_VALIDATOR"
grep -Fq 'let codesignExecutablePath = "/usr/bin/codesign"' "$ARTIFACT_VALIDATOR"
grep -Fq 'let otoolExecutablePath = "/usr/bin/otool"' "$ARTIFACT_VALIDATOR"
grep -Fq 'let dwarfdumpExecutablePath = "/usr/bin/dwarfdump"' "$ARTIFACT_VALIDATOR"
if grep -R -Eq -- '--(codesign|otool|dwarfdump)-executable-path|FAKE_BIN/(codesign|otool|dwarfdump)' \
    "$REPOSITORY_ROOT/ci_scripts/tests/ci_post_xcodebuild_test.sh" \
    "$REPOSITORY_ROOT/ci_scripts/tests/upload_dsyms_secrecy_test.sh"; then
    printf '%s\n' 'Shell integration reintroduced a production artifact verifier override.' >&2
    exit 105
fi

POST_BUILD_SCRIPT="$REPOSITORY_ROOT/ci_scripts/ci_post_xcodebuild.sh"
LOCAL_PREFLIGHT_LINE=$(grep -nF 'swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight' "$POST_BUILD_SCRIPT" | cut -d: -f1)
FETCH_LINE=$(grep -nF 'fetch_unshallow_repository' "$POST_BUILD_SCRIPT" | cut -d: -f1)
if [[ -z "$LOCAL_PREFLIGHT_LINE" || -z "$FETCH_LINE" || "$LOCAL_PREFLIGHT_LINE" -ge "$FETCH_LINE" ]]; then
    printf '%s\n' 'The complete local release preflight must run before the first remote read.' >&2
    exit 100
fi
grep -Fq 'ci_scripts/verify_xcodegen_is_current.sh' \
    "$REPOSITORY_ROOT/Tools/Sources/JunchatReleasePreflight.swift"

for release_metadata_path in \
    'project.yml' \
    'app.yml' \
    'docs/ELEMENT_CALL_CANDIDATE.md' \
    'ElementCall.release.json' \
    'Vendor/EmbeddedElementCall/**' \
    'ElementX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved' \
    '**/SupportingFiles/target.yml' \
    'Variants/**/*.yml' \
    'ElementX.xcodeproj/project.pbxproj' \
    'JUNCHAT_CHANGES.md' \
    'ElementX/SupportingFiles/Info.plist' \
    'NSE/SupportingFiles/Info.plist' \
    'ShareExtension/SupportingFiles/Info.plist'; do
    grep -Fq -- "- \"$release_metadata_path\"" "$WORKFLOW"
done

TARGET_SPECS=$(ruby -ryaml -e '
  project = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  project.fetch("include").map { |entry| entry.fetch("path") if entry.fetch("path").end_with?("target.yml") }.compact.each { |path| puts(path) }
' "$REPOSITORY_ROOT/project.yml")
while IFS= read -r target_spec; do
    case "$target_spec" in
        */SupportingFiles/target.yml)
            test -f "$REPOSITORY_ROOT/$target_spec"
            ;;
        *)
            printf 'XcodeGen target spec is not covered by the workflow glob: %s.\n' "$target_spec" >&2
            exit 99
            ;;
    esac
done <<< "$TARGET_SPECS"

if ! grep -Fq 'bash ci_scripts/verify_xcodegen_is_current.sh' "$WORKFLOW"; then
    printf '%s\n' 'Release hygiene must run the tested XcodeGen drift gate.' >&2
    exit 98
fi

XCODEGEN_GATE="$REPOSITORY_ROOT/ci_scripts/verify_xcodegen_is_current.sh"
grep -Fq 'xcodegen' "$XCODEGEN_GATE"
grep -Fq 'git diff --exit-code --' "$XCODEGEN_GATE"
grep -Fq 'git ls-files --others --exclude-standard' "$XCODEGEN_GATE"
grep -Fq "IGNORED_GENERATED_FILES=\$(git ls-files --others --ignored --exclude-standard --" "$XCODEGEN_GATE"

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
