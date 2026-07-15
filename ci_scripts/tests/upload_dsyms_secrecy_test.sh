#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/upload-dsyms-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
ARGV_LOG="$TEST_ROOT/sentry-argv.log"
ENV_MARKER="$TEST_ROOT/sentry-env-present"
COMMAND_LOG="$TEST_ROOT/tool-output.log"
AUTH_TOKEN='focused-test-sentry-token'
mkdir -p "$FAKE_BIN" "$TEST_ROOT/dSYMs"

cat > "$FAKE_BIN/sentry-cli" <<'EOF'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$@" > "$ARGV_LOG"
test -n "${SENTRY_AUTH_TOKEN:-}"
printf '%s\n' present > "$ENV_MARKER"
EOF
chmod +x "$FAKE_BIN/sentry-cli"

if ! (
    cd "$REPOSITORY_ROOT"
    PATH="$FAKE_BIN:$PATH" \
        ARGV_LOG="$ARGV_LOG" \
        ENV_MARKER="$ENV_MARKER" \
        SENTRY_AUTH_TOKEN="$AUTH_TOKEN" \
        swift run --disable-automatic-resolution -q tools ci upload-dsyms \
            --dsym-path "$TEST_ROOT/dSYMs"
) > "$COMMAND_LOG" 2>&1; then
    cat "$COMMAND_LOG" >&2
    exit 94
fi

if grep -Fq "$AUTH_TOKEN" "$COMMAND_LOG"; then
    printf '%s\n' 'Sentry auth token was written to tool logs.' >&2
    exit 92
fi

if grep -Fq "$AUTH_TOKEN" "$ARGV_LOG"; then
    printf '%s\n' 'Sentry auth token was passed in the process argument vector.' >&2
    exit 93
fi

test "$(cat "$ENV_MARKER")" = present
