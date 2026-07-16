#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEMPORARY_ROOT=${TMPDIR:-/tmp}
TEST_ROOT=$(mktemp -d "${TEMPORARY_ROOT%/}/upload-dsyms-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
ARGV_LOG="$TEST_ROOT/sentry-argv.log"
ENV_MARKER="$TEST_ROOT/sentry-env-present"
COMMAND_LOG="$TEST_ROOT/tool-output.log"
AUTH_TOKEN='focused-test-sentry-token'
FIXTURE_ROOT="$TEST_ROOT/repository"
ARCHIVE_PATH="$TEST_ROOT/Junchat.xcarchive"
SIGNED_APP_PATH="$ARCHIVE_PATH/Products/Applications/Junchat.app"
DSYM_CONTENTS="$ARCHIVE_PATH/dSYMs/Junchat.app.dSYM/Contents"
BINDING_DIRECTORY="$TEST_ROOT/binding"
BINDING_PATH="$BINDING_DIRECTORY/release-artifacts.json"
BINDING_DIGEST_PATH="$BINDING_DIRECTORY/release-artifacts.sha256"
mkdir -p "$FAKE_BIN" "$FIXTURE_ROOT" "$SIGNED_APP_PATH" "$DSYM_CONTENTS/Resources/DWARF" "$BINDING_DIRECTORY"
chmod 700 "$BINDING_DIRECTORY"
git -C "$REPOSITORY_ROOT" archive HEAD | tar -x -C "$FIXTURE_ROOT"
git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" -c user.name='Release Test' -c user.email=release-test@example.com \
    commit -qm 'Release fixture'

cat > "$ARCHIVE_PATH/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
<key>ApplicationPath</key><string>Applications/Junchat.app</string>
<key>CFBundleIdentifier</key><string>com.heyujk.junchat</string>
<key>CFBundleShortVersionString</key><string>1.8.2</string>
<key>CFBundleVersion</key><string>37</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>Name</key><string>Junchat</string>
<key>SchemeName</key><string>Junchat</string>
</dict></plist>
EOF
cat > "$SIGNED_APP_PATH/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Junchat</string>
<key>CFBundleIdentifier</key><string>com.heyujk.junchat</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.8.2</string>
<key>CFBundleVersion</key><string>37</string>
</dict></plist>
EOF
cat > "$DSYM_CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.apple.xcode.dsym.com.heyujk.junchat</string>
<key>CFBundlePackageType</key><string>dSYM</string>
</dict></plist>
EOF
cp /usr/bin/true "$SIGNED_APP_PATH/Junchat"
cp /usr/bin/true "$DSYM_CONTENTS/Resources/DWARF/Junchat"

cat > "$FAKE_BIN/codesign" <<'EOF'
#!/bin/bash
set -euo pipefail

case "$1" in
    --verify)
        test "$*" = "--verify --deep --strict $CI_APP_STORE_SIGNED_APP_PATH"
        ;;
    --display)
        test "$*" = "--display --verbose=4 $CI_APP_STORE_SIGNED_APP_PATH"
        printf '%s\n' \
            'Identifier=com.heyujk.junchat' \
            'TeamIdentifier=W834S4TA7S' \
            'Signature size=9000' >&2
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "$FAKE_BIN/otool" <<'EOF'
#!/bin/bash
set -euo pipefail

test "$1" = -hv
test -f "$2"
cat <<'OUTPUT'
Mach header
      magic cputype cpusubtype caps filetype ncmds sizeofcmds flags
 MH_MAGIC_64   ARM64        ALL  0x00  EXECUTE    20       2048 0x0
OUTPUT
EOF

cat > "$FAKE_BIN/dwarfdump" <<'EOF'
#!/bin/bash
set -euo pipefail

test "$1" = --uuid
test -e "$2"
printf 'UUID: 1AB9D6FA-27FF-3A79-9369-BE0E635A4AA2 (arm64) %s\n' "$2"
EOF

cat > "$FAKE_BIN/sentry-cli" <<'EOF'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$@" > "$ARGV_LOG"
test -n "${SENTRY_AUTH_TOKEN:-}"
printf '%s\n' present > "$ENV_MARKER"
EOF
chmod +x "$FAKE_BIN/codesign" "$FAKE_BIN/otool" "$FAKE_BIN/dwarfdump" "$FAKE_BIN/sentry-cli"

TOOLS_BIN_DIRECTORY=$(cd "$REPOSITORY_ROOT" && swift build --disable-automatic-resolution --show-bin-path)
TOOLS_BINARY="$TOOLS_BIN_DIRECTORY/tools"
(
    cd "$FIXTURE_ROOT"
    CI_ARCHIVE_PATH="$ARCHIVE_PATH" \
        CI_APP_STORE_SIGNED_APP_PATH="$SIGNED_APP_PATH" \
        "$TOOLS_BINARY" ci validate-junchat-release-preflight \
            --artifact-binding-path "$BINDING_PATH" \
            --artifact-binding-digest-path "$BINDING_DIGEST_PATH" \
            --codesign-executable-path "$FAKE_BIN/codesign" \
            --otool-executable-path "$FAKE_BIN/otool" \
            --dwarfdump-executable-path "$FAKE_BIN/dwarfdump"
) > /dev/null
EXPECTED_BINDING_DIGEST=$(tr -d '\n' < "$BINDING_DIGEST_PATH")
rm "$BINDING_DIGEST_PATH"

if ! (
    cd "$FIXTURE_ROOT"
    PATH="$FAKE_BIN:$PATH" \
        ARGV_LOG="$ARGV_LOG" \
        CI_ARCHIVE_PATH="$ARCHIVE_PATH" \
        CI_APP_STORE_SIGNED_APP_PATH="$SIGNED_APP_PATH" \
        ENV_MARKER="$ENV_MARKER" \
        SENTRY_AUTH_TOKEN="$AUTH_TOKEN" \
        "$TOOLS_BINARY" ci upload-dsyms \
            --dsym-path "$ARCHIVE_PATH/dSYMs" \
            --artifact-binding-path "$BINDING_PATH" \
            --expected-artifact-binding-digest "$EXPECTED_BINDING_DIGEST"
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
