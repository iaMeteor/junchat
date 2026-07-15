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
ARCHIVED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
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
        test "$*" = "rev-parse --verify HEAD"
        printf '%s\n' "$ARCHIVED_SHA"
        printf '%s\n' captured > "$ARCHIVED_SHA_MARKER"
        ;;
    tag)
        printf '%s\n' 'release/1.8.1'
        ;;
    log)
        printf '%s\n' "$@" > "$GIT_LOG_ARGUMENTS"
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

printf '%s\n' "$*" >> "$COMMAND_LOG"
if [[ "$*" == *"release-to-github"* ]] &&
   [[ ! -e "$ARCHIVED_SHA_MARKER" ]]; then
    printf '%s\n' 'Release orchestration ran before the archived SHA was captured.' >&2
    exit 92
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
    export ARCHIVED_SHA ARCHIVED_SHA_MARKER COMMAND_LOG FIXTURE_ROOT GIT_LOG_ARGUMENTS
    PATH="$FAKE_BIN:$PATH" \
        CI_ARCHIVE_PATH="$TEST_ROOT/archive" \
        CI_APP_STORE_SIGNED_APP_PATH="$FIXTURE_ROOT/signed-app" \
        CI_WORKFLOW=Release \
        bash ci_post_xcodebuild.sh
)

test -f "$FIXTURE_ROOT/TestFlight/WhatToTest.en-US.txt"
test "$(sed -n '1p' "$COMMAND_LOG")" = "run -q tools ci upload-dsyms --dsym-path $TEST_ROOT/archive/dSYMs"
test "$(sed -n '2p' "$COMMAND_LOG")" = 'run -q tools ci release-to-github'
test "$(sed -n '3p' "$GIT_LOG_ARGUMENTS")" = "release/1.8.1..$ARCHIVED_SHA"
