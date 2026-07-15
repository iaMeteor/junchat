#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ci-post-xcodebuild-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repository"
FAKE_BIN="$TEST_ROOT/bin"
COMMAND_LOG="$TEST_ROOT/swift-commands.log"
GIT_LOG_ARGUMENTS="$TEST_ROOT/git-log-arguments.log"
ARCHIVED_SHA_MARKER="$TEST_ROOT/archived-sha-captured"
BASELINE_SHA_MARKER="$TEST_ROOT/baseline-sha-captured"
NOTES_RANGE_MARKER="$TEST_ROOT/notes-range-validated"
VERSION_COMMAND_MARKER="$TEST_ROOT/version-command-ran"
ARCHIVED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREVIOUS_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$FIXTURE_ROOT/ci_scripts" "$FIXTURE_ROOT/signed-app" "$FAKE_BIN"
cp "$REPOSITORY_ROOT/ci_scripts/ci_common.sh" "$FIXTURE_ROOT/ci_scripts/"
cp "$REPOSITORY_ROOT/ci_scripts/ci_post_xcodebuild.sh" "$FIXTURE_ROOT/ci_scripts/"

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
set -euo pipefail

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
    tag)
        test "$*" = "tag --list release/* --sort=-version:refname"
        printf '%s\n' 'release/26.06.0' 'release/1.8.2' 'release/1.8.1'
        ;;
    merge-base)
        test "$*" = "merge-base --is-ancestor $PREVIOUS_SHA $ARCHIVED_SHA"
        printf '%s\n' captured > "$BASELINE_SHA_MARKER"
        ;;
    log)
        printf '%s\n' "$@" > "$GIT_LOG_ARGUMENTS"
        printf '%s\n' captured > "$NOTES_RANGE_MARKER"
        printf '%s\n' '- CI: focused release test'
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

if [[ "$*" == 'run -q tools ci current-release-version' ]]; then
    printf '%s\n' '1.8.2'
    printf '%s\n' captured > "$VERSION_COMMAND_MARKER"
    exit 0
fi

printf '%s\n' "$*" >> "$COMMAND_LOG"
if [[ "$*" == *"upload-dsyms"* || "$*" == *"release-to-github"* ]] &&
   [[ ! -e "$ARCHIVED_SHA_MARKER" || ! -e "$BASELINE_SHA_MARKER" || ! -e "$NOTES_RANGE_MARKER" ]]; then
    printf '%s\n' 'A remote-capable command ran before release notes were validated and frozen.' >&2
    exit 93
fi
if [[ "$*" == *"release-to-github"* ]] &&
   [[ -e "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt" ]]; then
    printf '%s\n' 'Release preflight ran after TestFlight notes mutated the worktree.' >&2
    exit 91
fi
EOF

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/swift"

(
    cd "$FIXTURE_ROOT/ci_scripts"
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER BASELINE_SHA_MARKER COMMAND_LOG FIXTURE_ROOT GIT_LOG_ARGUMENTS NOTES_RANGE_MARKER PREVIOUS_SHA VERSION_COMMAND_MARKER
    PATH="$FAKE_BIN:$PATH" \
        CI_ARCHIVE_PATH="$TEST_ROOT/archive" \
        CI_APP_STORE_SIGNED_APP_PATH="$FIXTURE_ROOT/signed-app" \
        CI_WORKFLOW=Release \
        bash ci_post_xcodebuild.sh
)

test -f "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt"
test -f "$VERSION_COMMAND_MARKER"
test -f "$BASELINE_SHA_MARKER"
test -f "$NOTES_RANGE_MARKER"
test "$(sed -n '1p' "$COMMAND_LOG")" = "run -q tools ci upload-dsyms --dsym-path $TEST_ROOT/archive/dSYMs"
test "$(sed -n '2p' "$COMMAND_LOG")" = 'run -q tools ci release-to-github'
test "$(sed -n '3p' "$GIT_LOG_ARGUMENTS")" = "$PREVIOUS_SHA..$ARCHIVED_SHA"
