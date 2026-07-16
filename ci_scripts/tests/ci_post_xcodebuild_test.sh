#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ci-post-xcodebuild-test.XXXXXX")
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
ARCHIVED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREVIOUS_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REPOSITORY_URL=git@github.com:acme/junchat-ios.git
mkdir -p "$FIXTURE_ROOT/ci_scripts" "$FIXTURE_ROOT/signed-app" "$FAKE_BIN"
cp "$REPOSITORY_ROOT/ci_scripts/ci_common.sh" "$FIXTURE_ROOT/ci_scripts/"
cp "$REPOSITORY_ROOT/ci_scripts/ci_post_xcodebuild.sh" "$FIXTURE_ROOT/ci_scripts/"

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'git %s\n' "$*" >> "$ENTRY_COMMAND_LOG"

case "${1:-}" in
    fetch)
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

if [[ "$*" == 'run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight' ]]; then
    printf '%s\n' captured > "$LOCAL_PREFLIGHT_MARKER"
    if [[ "${LOCAL_PREFLIGHT_FAIL:-0}" = 1 ]]; then
        exit 92
    fi
    exit 0
fi

if [[ "$*" == 'run -q tools ci current-release-version' ]]; then
    printf '%s\n' '1.8.2'
    printf '%s\n' captured > "$VERSION_COMMAND_MARKER"
    exit 0
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
if [[ "$*" == *"release-to-github"* ]] &&
   [[ -e "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt" ]]; then
    printf '%s\n' 'Release preflight ran after TestFlight notes mutated the worktree.' >&2
    exit 91
fi
EOF

cat > "$FAKE_BIN/sentry-cli" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'sentry-cli %s\n' "$*" >> "$ENTRY_COMMAND_LOG"
EOF

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/swift" "$FAKE_BIN/sentry-cli"

assert_invalid_identity_has_no_commands() {
    local scenario="$1"
    shift

    rm -f "$ENTRY_COMMAND_LOG"
    if (
        cd "$FIXTURE_ROOT/ci_scripts"
        export ARCHIVED_SHA ARCHIVED_SHA_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FIXTURE_ROOT GIT_LOG_ARGUMENTS NOTES_RANGE_MARKER PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REPOSITORY_URL VERSION_COMMAND_MARKER
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

rm -f "$ENTRY_COMMAND_LOG"

if (
    cd "$FIXTURE_ROOT/ci_scripts"
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER NOTES_RANGE_MARKER PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REPOSITORY_URL VERSION_COMMAND_MARKER
    PATH="$FAKE_BIN:$PATH" \
        CI=TRUE \
        CI_ARCHIVE_PATH="$TEST_ROOT/archive" \
        CI_APP_STORE_SIGNED_APP_PATH="$FIXTURE_ROOT/signed-app" \
        CI_WORKFLOW_ID=release-workflow-id \
        CI_WORKFLOW=Release \
        CI_XCODEBUILD_ACTION=archive \
        CI_XCODE_CLOUD=TRUE \
        LOCAL_PREFLIGHT_FAIL=1 \
        bash ci_post_xcodebuild.sh
); then
    printf '%s\n' 'A Release workflow continued after local preflight failed.' >&2
    exit 97
fi
test -f "$LOCAL_PREFLIGHT_MARKER"
test "$(wc -l < "$ENTRY_COMMAND_LOG" | tr -d '[:space:]')" = 1
test "$(sed -n '1p' "$ENTRY_COMMAND_LOG")" = 'swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight'
if grep -Eq '^git fetch|published-junchat-release-tags|upload-dsyms|release-to-github|^sentry-cli ' "$ENTRY_COMMAND_LOG"; then
    printf '%s\n' 'Local preflight failure allowed a remote read or side effect:' >&2
    cat "$ENTRY_COMMAND_LOG" >&2
    exit 98
fi

rm -f "$ENTRY_COMMAND_LOG" "$LOCAL_PREFLIGHT_MARKER"

(
    cd "$FIXTURE_ROOT/ci_scripts"
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER NOTES_RANGE_MARKER PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REPOSITORY_URL VERSION_COMMAND_MARKER
    PATH="$FAKE_BIN:$PATH" \
        CI=TRUE \
        CI_ARCHIVE_PATH="$TEST_ROOT/archive" \
        CI_APP_STORE_SIGNED_APP_PATH="$FIXTURE_ROOT/signed-app" \
        CI_WORKFLOW_ID=release-workflow-id \
        CI_WORKFLOW=Release \
        CI_XCODEBUILD_ACTION=archive \
        CI_XCODE_CLOUD=TRUE \
        bash ci_post_xcodebuild.sh
)

test -f "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt"
test -f "$LOCAL_PREFLIGHT_MARKER"
test "$(sed -n '1p' "$ENTRY_COMMAND_LOG")" = 'swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight'
test -f "$VERSION_COMMAND_MARKER"
test -f "$PUBLISHED_RELEASE_SNAPSHOT_MARKER"
test -f "$BASELINE_SHA_MARKER"
test -f "$NOTES_RANGE_MARKER"
test "$(sed -n '1p' "$COMMAND_LOG")" = "run -q tools ci upload-dsyms --dsym-path $TEST_ROOT/archive/dSYMs"
test "$(sed -n '2p' "$COMMAND_LOG")" = 'run -q tools ci release-to-github'
test "$(sed -n '3p' "$GIT_LOG_ARGUMENTS")" = "$PREVIOUS_SHA..$ARCHIVED_SHA"

rm -f "$COMMAND_LOG" "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt"
if (
    cd "$FIXTURE_ROOT/ci_scripts"
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER BASELINE_SHA_MARKER COMMAND_LOG ENTRY_COMMAND_LOG FIXTURE_ROOT GIT_LOG_ARGUMENTS LOCAL_PREFLIGHT_MARKER NOTES_RANGE_MARKER PREVIOUS_SHA PUBLISHED_RELEASE_SNAPSHOT_MARKER REPOSITORY_URL VERSION_COMMAND_MARKER
    PATH="$FAKE_BIN:$PATH" \
        CI=TRUE \
        CI_ARCHIVE_PATH="$TEST_ROOT/archive" \
        CI_APP_STORE_SIGNED_APP_PATH="$FIXTURE_ROOT/signed-app" \
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
