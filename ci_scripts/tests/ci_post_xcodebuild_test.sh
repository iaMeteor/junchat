#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEMPORARY_ROOT=${TMPDIR:-/tmp}
TEST_ROOT=$(mktemp -d "${TEMPORARY_ROOT%/}/ci-post-xcodebuild-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repository"
FAKE_BIN="$TEST_ROOT/bin"
COMMAND_LOG="$TEST_ROOT/swift-commands.log"
ENTRY_COMMAND_LOG="$TEST_ROOT/entry-commands.log"
GIT_LOG_ARGUMENTS="$TEST_ROOT/git-log-arguments.log"
ARCHIVED_SHA_MARKER="$TEST_ROOT/archived-sha-captured"
BASELINE_SHA_MARKER="$TEST_ROOT/baseline-sha-captured"
NOTES_RANGE_MARKER="$TEST_ROOT/notes-range-validated"
VERSION_COMMAND_MARKER="$TEST_ROOT/version-command-ran"
PUBLISHED_RELEASE_SNAPSHOT_MARKER="$TEST_ROOT/published-release-snapshot-captured"
LOCAL_PREFLIGHT_MARKER="$TEST_ROOT/local-preflight-ran"
ARTIFACT_BINDING_MARKER="$TEST_ROOT/artifact-binding-revalidated"
SENTRY_MARKER="$TEST_ROOT/sentry-invoked"
RELEASE_MARKER="$TEST_ROOT/release-invoked"
ARCHIVED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREVIOUS_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REPOSITORY_URL=git@github.com:acme/junchat-ios.git
SWIFT_EXECUTABLE=$(command -v swift)
XCODEGEN_EXECUTABLE=$(command -v xcodegen)
TOOLS_BIN_DIRECTORY=$($SWIFT_EXECUTABLE build --disable-automatic-resolution --show-bin-path)
REAL_TOOLS_BINARY="$TOOLS_BIN_DIRECTORY/tools"
PREFLIGHT_PATH="$(dirname "$XCODEGEN_EXECUTABLE"):/usr/bin:/bin:/usr/sbin:/sbin"
IFS=$'\t' read -r FIXTURE_VERSION FIXTURE_BUILD < <(
    "$REAL_TOOLS_BINARY" ci current-release-version --include-build
)
[[ -n "$FIXTURE_VERSION" && "$FIXTURE_BUILD" =~ ^[1-9][0-9]*$ ]]
export REPOSITORY_ROOT SWIFT_EXECUTABLE
mkdir -p "$FIXTURE_ROOT" "$FAKE_BIN"
git archive HEAD | tar -x -C "$FIXTURE_ROOT"
cp "$REPOSITORY_ROOT/ci_scripts/ci_common.sh" "$FIXTURE_ROOT/ci_scripts/"
cp "$REPOSITORY_ROOT/ci_scripts/ci_post_xcodebuild.sh" "$FIXTURE_ROOT/ci_scripts/"
cp "$REPOSITORY_ROOT/ci_scripts/verify_xcodegen_is_current.sh" "$FIXTURE_ROOT/ci_scripts/"
git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" -c user.name='Release Test' -c user.email=release-test@example.com \
    commit -qm 'Release fixture'

create_valid_archive() {
    local archive_path="$1"
    local app_path="$archive_path/Products/Applications/Junchat.app"
    local dsym_contents="$archive_path/dSYMs/Junchat.app.dSYM/Contents"

    mkdir -p "$app_path" "$dsym_contents/Resources/DWARF"
    cat > "$archive_path/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
<key>ApplicationPath</key><string>Applications/Junchat.app</string>
<key>CFBundleIdentifier</key><string>com.heyujk.junchat</string>
<key>CFBundleShortVersionString</key><string>$FIXTURE_VERSION</string>
<key>CFBundleVersion</key><string>$FIXTURE_BUILD</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>Name</key><string>Junchat</string>
<key>SchemeName</key><string>Junchat</string>
</dict></plist>
EOF
    cat > "$app_path/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Junchat</string>
<key>CFBundleIdentifier</key><string>com.heyujk.junchat</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$FIXTURE_VERSION</string>
<key>CFBundleVersion</key><string>$FIXTURE_BUILD</string>
</dict></plist>
EOF
    cat > "$dsym_contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.apple.xcode.dsym.com.heyujk.junchat</string>
<key>CFBundlePackageType</key><string>dSYM</string>
</dict></plist>
EOF
    cp /usr/bin/true "$app_path/Junchat"
    cp /usr/bin/true "$dsym_contents/Resources/DWARF/Junchat"
}

VALID_ARCHIVE="$TEST_ROOT/Junchat.xcarchive"
VALID_SIGNED_APP="$VALID_ARCHIVE/Products/Applications/Junchat.app"
MUTATION_TARGET="$VALID_ARCHIVE/dSYMs/Junchat.app.dSYM/Contents/Resources/DWARF/Junchat"
create_valid_archive "$VALID_ARCHIVE"

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'git %s\n' "$*" >> "$ENTRY_COMMAND_LOG"

if [[ "${1:-}" = fetch && ! -f "$LOCAL_PREFLIGHT_MARKER" ]]; then
    printf '%s\n' 'The production local preflight was bypassed.' >&2
    exit 88
fi

case "${1:-}" in
    fetch)
        if [[ "${MUTATE_AFTER_PREFLIGHT:-0}" = 1 ]]; then
            printf '%s\n' mutation >> "$MUTATION_TARGET"
        fi
        ;;
    rev-parse)
        case "$*" in
            "rev-parse --verify HEAD")
                printf '%s\n' "$ARCHIVED_SHA"
                printf '%s\n' captured > "$ARCHIVED_SHA_MARKER"
                ;;
            "rev-parse --verify $ARCHIVED_SHA^{commit}")
                printf '%s\n' "$ARCHIVED_SHA"
                ;;
            "rev-parse --verify release/1.8.1^{commit}")
                printf '%s\n' "$PREVIOUS_SHA"
                ;;
            *)
                printf 'Unexpected git rev-parse command: %s\n' "$*" >&2
                exit 89
                ;;
        esac
        ;;
    remote)
        test "$*" = "remote get-url origin"
        printf '%s\n' "$REPOSITORY_URL"
        ;;
    merge-base)
        test "$*" = "merge-base --is-ancestor $PREVIOUS_SHA $ARCHIVED_SHA"
        printf '%s\n' captured > "$BASELINE_SHA_MARKER"
        ;;
    log)
        printf '%s\n' "$@" > "$GIT_LOG_ARGUMENTS"
        printf '%s\n' captured > "$NOTES_RANGE_MARKER"
        if [[ "${OVERSIZED_NOTES:-0}" = 1 ]]; then
            printf '%*s' 4001 '' | tr ' ' a
        else
            printf '%s\n' '- CI: focused release test'
        fi
        ;;
    *)
        printf 'Unexpected git command: %s\n' "$*" >&2
        exit 90
        ;;
esac
EOF

cat > "$FAKE_BIN/swift" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'swift %s\n' "$*" >> "$ENTRY_COMMAND_LOG"

run_real_tools() {
    local arguments=("$@")
    local index
    local tools_path=${REAL_TOOLS_PATH:-$PREFLIGHT_PATH}

    for ((index = 0; index < ${#arguments[@]}; index++)); do
        if [[ "${arguments[$index]}" = tools ]]; then
            PATH="$tools_path" "$REAL_TOOLS_BINARY" "${arguments[@]:index + 1}"
            return
        fi
    done
    printf '%s\n' 'Unable to locate the tools command boundary.' >&2
    return 92
}

export_release_artifact_binding() {
    local arguments=("$@")
    local binding_path=""
    local digest_path=""
    local index

    for ((index = 0; index < ${#arguments[@]}; index++)); do
        case "${arguments[$index]}" in
            --artifact-binding-path)
                binding_path="${arguments[$((index + 1))]}"
                ;;
            --artifact-binding-digest-path)
                digest_path="${arguments[$((index + 1))]}"
                ;;
        esac
    done
    if [[ -z "$binding_path" || -z "$digest_path" ]]; then
        printf '%s\n' 'The production preflight binding arguments were not preserved.' >&2
        return 84
    fi

    if PATH="$PREFLIGHT_PATH" \
        JUNCHAT_RELEASE_TEST_BINDING_DIGEST_PATH="$digest_path" \
        JUNCHAT_RELEASE_TEST_BINDING_PATH="$binding_path" \
        JUNCHAT_RELEASE_TEST_EXPORT_BINDING=1 \
        JUNCHAT_RELEASE_TEST_REPOSITORY_PATH="$FIXTURE_ROOT" \
        "$SWIFT_EXECUTABLE" test --package-path "$REPOSITORY_ROOT" --disable-automatic-resolution \
            --filter JunchatReleasePreflightTests/testExportsValidatedArtifactBindingForShellIntegration \
            > "${LOCAL_PREFLIGHT_MARKER}.log" 2>&1; then
        return 0
    fi
    cat "${LOCAL_PREFLIGHT_MARKER}.log" >&2
    return 85
}

if [[ "$*" == *'tools ci validate-junchat-release-preflight --artifact-binding-path '* ]]; then
    if export_release_artifact_binding "$@"; then
        printf '%s\n' captured > "$LOCAL_PREFLIGHT_MARKER"
        exit 0
    else
        exit $?
    fi
fi

if [[ "$*" == *'tools ci validate-junchat-release-artifact-binding --artifact-binding-path '* ]]; then
    if run_real_tools "$@"; then
        printf '%s\n' captured > "$ARTIFACT_BINDING_MARKER"
        exit 0
    else
        exit $?
    fi
fi

if [[ "$*" == 'run -q tools ci current-release-version' ]]; then
    if PATH="$PREFLIGHT_PATH" "$REAL_TOOLS_BINARY" ci current-release-version; then
        printf '%s\n' captured > "$VERSION_COMMAND_MARKER"
        exit 0
    else
        exit $?
    fi
fi

if [[ "$*" == "run -q tools ci published-junchat-release-tags --repository-url $REPOSITORY_URL" ]]; then
    printf '101\trelease/1.8.1\t%s\n' "$PREVIOUS_SHA"
    printf '%s\n' captured > "$PUBLISHED_RELEASE_SNAPSHOT_MARKER"
    exit 0
fi

printf '%s\n' "$*" >> "$COMMAND_LOG"
if [[ "$*" == *"upload-dsyms"* || "$*" == *"release-to-github"* ]] &&
   [[ ! -e "$ARCHIVED_SHA_MARKER" || ! -e "$PUBLISHED_RELEASE_SNAPSHOT_MARKER" ||
      ! -e "$BASELINE_SHA_MARKER" || ! -e "$NOTES_RANGE_MARKER" ]]; then
    printf '%s\n' 'A remote-capable command ran before release notes were validated and frozen.' >&2
    exit 93
fi
if [[ "$*" == *"upload-dsyms"* ]]; then
    if [[ ! -e "$ARTIFACT_BINDING_MARKER" ]]; then
        printf '%s\n' 'dSYM upload ran without an immediate production artifact-binding check.' >&2
        exit 87
    fi
    rm "$ARTIFACT_BINDING_MARKER"
    SENTRY_AUTH_TOKEN=local-test-token REAL_TOOLS_PATH="$FAKE_BIN:$PREFLIGHT_PATH" run_real_tools "$@"
    exit $?
fi
if [[ "$*" == *"release-to-github"* ]] &&
   [[ -e "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt" ]]; then
    printf '%s\n' 'Release preflight ran after TestFlight notes mutated the worktree.' >&2
    exit 91
fi
if [[ "$*" == *"release-to-github"* ]]; then
    if [[ ! -e "$ARTIFACT_BINDING_MARKER" ]]; then
        printf '%s\n' 'GitHub release ran without an immediate production artifact-binding check.' >&2
        exit 86
    fi
    printf '%s\n' captured > "$RELEASE_MARKER"
    exit 0
fi
EOF

cat > "$FAKE_BIN/sentry-cli" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'sentry-cli %s\n' "$*" >> "$ENTRY_COMMAND_LOG"
printf '%s\n' captured > "$SENTRY_MARKER"
if [[ "${MUTATE_AFTER_UPLOAD:-0}" = 1 ]]; then
    printf '%s\n' mutation >> "$MUTATION_TARGET"
fi
EOF

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/swift" "$FAKE_BIN/sentry-cli"

assert_invalid_identity_has_no_commands() {
    local scenario="$1"
    shift

    rm -f "$ENTRY_COMMAND_LOG"
    if (
        cd "$FIXTURE_ROOT/ci_scripts"
        export ARCHIVED_SHA ARCHIVED_SHA_MARKER ARTIFACT_BINDING_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FAKE_BIN FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER MUTATION_TARGET NOTES_RANGE_MARKER PREFLIGHT_PATH PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REAL_TOOLS_BINARY RELEASE_MARKER REPOSITORY_URL SENTRY_MARKER VERSION_COMMAND_MARKER
        PATH="$FAKE_BIN:$PATH" "$@" bash ci_post_xcodebuild.sh
    ); then
        printf 'Invalid Xcode Cloud identity succeeded: %s.\n' "$scenario" >&2
        exit 95
    fi
    if [[ -s "$ENTRY_COMMAND_LOG" ]]; then
        printf 'Invalid Xcode Cloud identity ran commands (%s):\n' "$scenario" >&2
        cat "$ENTRY_COMMAND_LOG" >&2
        exit 96
    fi
}

assert_invalid_identity_has_no_commands missing-ci \
    env -u CI CI_XCODE_CLOUD=TRUE CI_WORKFLOW=Release CI_WORKFLOW_ID=release-workflow-id CI_XCODEBUILD_ACTION=archive
assert_invalid_identity_has_no_commands missing-xcode-cloud \
    env -u CI_XCODE_CLOUD CI=TRUE CI_WORKFLOW=Release CI_WORKFLOW_ID=release-workflow-id CI_XCODEBUILD_ACTION=archive
assert_invalid_identity_has_no_commands missing-workflow \
    env -u CI_WORKFLOW CI=TRUE CI_XCODE_CLOUD=TRUE CI_WORKFLOW_ID=release-workflow-id CI_XCODEBUILD_ACTION=archive
assert_invalid_identity_has_no_commands missing-workflow-id \
    env -u CI_WORKFLOW_ID CI=TRUE CI_XCODE_CLOUD=TRUE CI_WORKFLOW=Release CI_XCODEBUILD_ACTION=archive
assert_invalid_identity_has_no_commands missing-action \
    env -u CI_XCODEBUILD_ACTION CI=TRUE CI_XCODE_CLOUD=TRUE CI_WORKFLOW=Release CI_WORKFLOW_ID=release-workflow-id
assert_invalid_identity_has_no_commands wrong-action \
    env CI=TRUE CI_XCODE_CLOUD=TRUE CI_WORKFLOW=Release CI_WORKFLOW_ID=release-workflow-id CI_XCODEBUILD_ACTION=build
assert_invalid_identity_has_no_commands wrong-workflow \
    env CI=TRUE CI_XCODE_CLOUD=TRUE CI_WORKFLOW='Pull Request' CI_WORKFLOW_ID=pull-request-workflow-id CI_XCODEBUILD_ACTION=archive

assert_artifact_preflight_failure() {
    local scenario="$1"
    shift

    rm -f "$COMMAND_LOG" "$ENTRY_COMMAND_LOG" "$LOCAL_PREFLIGHT_MARKER"
    if (
        cd "$FIXTURE_ROOT/ci_scripts"
        export ARCHIVED_SHA ARCHIVED_SHA_MARKER ARTIFACT_BINDING_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FAKE_BIN FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER MUTATION_TARGET NOTES_RANGE_MARKER PREFLIGHT_PATH PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REAL_TOOLS_BINARY RELEASE_MARKER REPOSITORY_URL SENTRY_MARKER VERSION_COMMAND_MARKER
        PATH="$FAKE_BIN:$PATH" "$@" bash ci_post_xcodebuild.sh
    ); then
        printf 'Malformed release artifact succeeded: %s.\n' "$scenario" >&2
        exit 97
    fi
    test ! -e "$LOCAL_PREFLIGHT_MARKER"
    test "$(wc -l < "$ENTRY_COMMAND_LOG" | tr -d '[:space:]')" = 1
    grep -Eq '^swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight --artifact-binding-path /.* --artifact-binding-digest-path /' "$ENTRY_COMMAND_LOG"
    if grep -Eq '^git fetch|published-junchat-release-tags|upload-dsyms|release-to-github|^sentry-cli ' "$ENTRY_COMMAND_LOG"; then
        printf 'Artifact preflight failure allowed a remote read or side effect (%s):\n' "$scenario" >&2
        cat "$ENTRY_COMMAND_LOG" >&2
        exit 98
    fi
    test ! -s "$COMMAND_LOG"
}

MISSING_INFO_ARCHIVE="$TEST_ROOT/missing-info.xcarchive"
MISSING_DSYM_ARCHIVE="$TEST_ROOT/missing-dsym.xcarchive"
UNRELATED_SIGNED_APP="$TEST_ROOT/Unrelated/Junchat.app"
mkdir -p "$(dirname "$UNRELATED_SIGNED_APP")"
cp -R "$VALID_ARCHIVE" "$MISSING_INFO_ARCHIVE"
cp -R "$VALID_ARCHIVE" "$MISSING_DSYM_ARCHIVE"
cp -R "$VALID_SIGNED_APP" "$UNRELATED_SIGNED_APP"
rm "$MISSING_INFO_ARCHIVE/Info.plist"
rm -rf "$MISSING_DSYM_ARCHIVE/dSYMs"

assert_artifact_preflight_failure missing-archive-path \
    env -u CI_ARCHIVE_PATH CI=TRUE CI_APP_STORE_SIGNED_APP_PATH="$VALID_SIGNED_APP" CI_WORKFLOW_ID=release-workflow-id CI_WORKFLOW=Release CI_XCODEBUILD_ACTION=archive CI_XCODE_CLOUD=TRUE
assert_artifact_preflight_failure noncanonical-archive-path \
    env CI=TRUE CI_ARCHIVE_PATH="$TEST_ROOT/./Junchat.xcarchive" CI_APP_STORE_SIGNED_APP_PATH="$VALID_SIGNED_APP" CI_WORKFLOW_ID=release-workflow-id CI_WORKFLOW=Release CI_XCODEBUILD_ACTION=archive CI_XCODE_CLOUD=TRUE
assert_artifact_preflight_failure missing-archive-info \
    env CI=TRUE CI_ARCHIVE_PATH="$MISSING_INFO_ARCHIVE" CI_APP_STORE_SIGNED_APP_PATH="$MISSING_INFO_ARCHIVE/Products/Applications/Junchat.app" CI_WORKFLOW_ID=release-workflow-id CI_WORKFLOW=Release CI_XCODEBUILD_ACTION=archive CI_XCODE_CLOUD=TRUE
assert_artifact_preflight_failure unrelated-signed-app \
    env CI=TRUE CI_ARCHIVE_PATH="$VALID_ARCHIVE" CI_APP_STORE_SIGNED_APP_PATH="$UNRELATED_SIGNED_APP" CI_WORKFLOW_ID=release-workflow-id CI_WORKFLOW=Release CI_XCODEBUILD_ACTION=archive CI_XCODE_CLOUD=TRUE
assert_artifact_preflight_failure missing-dsym \
    env CI=TRUE CI_ARCHIVE_PATH="$MISSING_DSYM_ARCHIVE" CI_APP_STORE_SIGNED_APP_PATH="$MISSING_DSYM_ARCHIVE/Products/Applications/Junchat.app" CI_WORKFLOW_ID=release-workflow-id CI_WORKFLOW=Release CI_XCODEBUILD_ACTION=archive CI_XCODE_CLOUD=TRUE

BYPASSED_POST_BUILD="$FIXTURE_ROOT/ci_scripts/ci_post_xcodebuild_bypass.sh"
awk '
    /^swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight/ {
        print "printf '\''%064d\\n'\'' 0 > \"$RELEASE_ARTIFACT_BINDING_DIGEST_PATH\" # mutation: bypass production preflight"
        bypassing = 1
        next
    }
    bypassing && /--artifact-binding-digest-path/ {
        bypassing = 0
        next
    }
    !bypassing { print }
' "$FIXTURE_ROOT/ci_scripts/ci_post_xcodebuild.sh" > "$BYPASSED_POST_BUILD"
rm -f "$ENTRY_COMMAND_LOG" "$LOCAL_PREFLIGHT_MARKER"
if (
    cd "$FIXTURE_ROOT/ci_scripts"
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER ARTIFACT_BINDING_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FAKE_BIN FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER MUTATION_TARGET NOTES_RANGE_MARKER PREFLIGHT_PATH PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REAL_TOOLS_BINARY RELEASE_MARKER REPOSITORY_URL SENTRY_MARKER VERSION_COMMAND_MARKER
    PATH="$FAKE_BIN:$PATH" \
        CI=TRUE \
        CI_ARCHIVE_PATH="$VALID_ARCHIVE" \
        CI_APP_STORE_SIGNED_APP_PATH="$VALID_SIGNED_APP" \
        CI_WORKFLOW_ID=release-workflow-id \
        CI_WORKFLOW=Release \
        CI_XCODEBUILD_ACTION=archive \
        CI_XCODE_CLOUD=TRUE \
        bash ci_post_xcodebuild_bypass.sh
); then
    printf '%s\n' 'The post-build harness did not detect a bypassed production preflight.' >&2
    exit 99
fi
grep -Fq 'git fetch --unshallow --quiet' "$ENTRY_COMMAND_LOG"
test ! -e "$LOCAL_PREFLIGHT_MARKER"
rm -f "$BYPASSED_POST_BUILD" "$ENTRY_COMMAND_LOG"

(
    cd "$FIXTURE_ROOT/ci_scripts"
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER ARTIFACT_BINDING_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FAKE_BIN FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER MUTATION_TARGET NOTES_RANGE_MARKER PREFLIGHT_PATH PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REAL_TOOLS_BINARY RELEASE_MARKER REPOSITORY_URL SENTRY_MARKER VERSION_COMMAND_MARKER
    PATH="$FAKE_BIN:$PATH" \
        CI=TRUE \
        CI_ARCHIVE_PATH="$VALID_ARCHIVE" \
        CI_APP_STORE_SIGNED_APP_PATH="$VALID_SIGNED_APP" \
        CI_WORKFLOW_ID=release-workflow-id \
        CI_WORKFLOW=Release \
        CI_XCODEBUILD_ACTION=archive \
        CI_XCODE_CLOUD=TRUE \
        bash ci_post_xcodebuild.sh
)

test -f "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt"
test -f "$LOCAL_PREFLIGHT_MARKER"
grep -Eq '^swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight --artifact-binding-path /.* --artifact-binding-digest-path /' "$ENTRY_COMMAND_LOG"
test -f "$VERSION_COMMAND_MARKER"
test -f "$PUBLISHED_RELEASE_SNAPSHOT_MARKER"
test -f "$BASELINE_SHA_MARKER"
test -f "$NOTES_RANGE_MARKER"
grep -Eq "^run -q tools ci upload-dsyms --dsym-path $VALID_ARCHIVE/dSYMs --artifact-binding-path /.* --expected-artifact-binding-digest [0-9a-f]{64}$" "$COMMAND_LOG"
grep -Eq '^run -q tools ci release-to-github --artifact-binding-path /.* --expected-artifact-binding-digest [0-9a-f]{64}$' "$COMMAND_LOG"
test -f "$SENTRY_MARKER"
test -f "$RELEASE_MARKER"
test "$(sed -n '3p' "$GIT_LOG_ARGUMENTS")" = "$PREVIOUS_SHA..$ARCHIVED_SHA"

assert_bound_artifact_mutation_fails() {
    local mutation_variable="$1"
    local expect_sentry="$2"

    create_valid_archive "$VALID_ARCHIVE"
    rm -f "$ARTIFACT_BINDING_MARKER" "$COMMAND_LOG" "$ENTRY_COMMAND_LOG" "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt" "$RELEASE_MARKER" "$SENTRY_MARKER"
    if (
        cd "$FIXTURE_ROOT/ci_scripts"
        export ARCHIVED_SHA ARCHIVED_SHA_MARKER ARTIFACT_BINDING_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FAKE_BIN FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER MUTATION_TARGET NOTES_RANGE_MARKER PREFLIGHT_PATH PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REAL_TOOLS_BINARY RELEASE_MARKER REPOSITORY_URL SENTRY_MARKER VERSION_COMMAND_MARKER
        env PATH="$FAKE_BIN:$PATH" \
            CI=TRUE \
            CI_ARCHIVE_PATH="$VALID_ARCHIVE" \
            CI_APP_STORE_SIGNED_APP_PATH="$VALID_SIGNED_APP" \
            CI_WORKFLOW_ID=release-workflow-id \
            CI_WORKFLOW=Release \
            CI_XCODEBUILD_ACTION=archive \
            CI_XCODE_CLOUD=TRUE \
            "$mutation_variable=1" \
            bash ci_post_xcodebuild.sh
    ); then
        printf 'Artifact mutation escaped the production binding: %s.\n' "$mutation_variable" >&2
        exit 85
    fi
    test ! -e "$RELEASE_MARKER"
    if [[ "$expect_sentry" = yes ]]; then
        test -f "$SENTRY_MARKER"
    else
        test ! -e "$SENTRY_MARKER"
    fi
}

assert_bound_artifact_mutation_fails MUTATE_AFTER_PREFLIGHT no
assert_bound_artifact_mutation_fails MUTATE_AFTER_UPLOAD yes

create_valid_archive "$VALID_ARCHIVE"
rm -f "$ARTIFACT_BINDING_MARKER" "$COMMAND_LOG" "$ENTRY_COMMAND_LOG" "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt" "$RELEASE_MARKER" "$SENTRY_MARKER"
if (
    cd "$FIXTURE_ROOT/ci_scripts"
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER ARTIFACT_BINDING_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FAKE_BIN FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER MUTATION_TARGET NOTES_RANGE_MARKER PREFLIGHT_PATH PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REAL_TOOLS_BINARY RELEASE_MARKER REPOSITORY_URL SENTRY_MARKER VERSION_COMMAND_MARKER
    PATH="$FAKE_BIN:$PATH" \
        CI=TRUE \
        CI_ARCHIVE_PATH="$VALID_ARCHIVE" \
        CI_APP_STORE_SIGNED_APP_PATH="$VALID_SIGNED_APP" \
        CI_WORKFLOW_ID=release-workflow-id \
        CI_WORKFLOW=Release \
        CI_XCODEBUILD_ACTION=archive \
        CI_XCODE_CLOUD=TRUE \
        OVERSIZED_NOTES=1 \
        bash ci_post_xcodebuild.sh
); then
    printf '%s\n' 'A Release workflow with 4,001-scalar WhatToTest notes succeeded.' >&2
    exit 94
fi
test ! -s "$COMMAND_LOG"
test ! -e "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt"
