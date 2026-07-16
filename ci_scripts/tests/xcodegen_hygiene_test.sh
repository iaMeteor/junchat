#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
GATE_SCRIPT="$REPOSITORY_ROOT/ci_scripts/verify_xcodegen_is_current.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xcodegen-hygiene-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/xcodegen" <<'EOF'
#!/bin/bash
set -euo pipefail

case "$XCODEGEN_TEST_MODE" in
    clean)
        ;;
    tracked)
        printf '%s\n' changed > ElementX.xcodeproj/project.pbxproj
        ;;
    staged)
        printf '%s\n' changed > ElementX.xcodeproj/project.pbxproj
        git add ElementX.xcodeproj/project.pbxproj
        ;;
    untracked)
        printf '%s\n' generated > newly-generated.pbxproj
        ;;
    ignored-generated)
        printf '%s\n' generated > ElementX.xcodeproj/ignored-generated.pbxproj
        ;;
    unrelated-ignored)
        mkdir -p build
        printf '%s\n' cache > build/unrelated-output
        ;;
    *)
        printf 'Unexpected XCODEGEN_TEST_MODE: %s\n' "$XCODEGEN_TEST_MODE" >&2
        exit 91
        ;;
esac
EOF
chmod +x "$FAKE_BIN/xcodegen"

create_repository() {
    local scenario="$1"
    local repository="$TEST_ROOT/$scenario"

    git init -q "$repository"
    mkdir -p "$repository/ElementX.xcodeproj"
    printf '%s\n' current > "$repository/ElementX.xcodeproj/project.pbxproj"
    cat > "$repository/.gitignore" <<'EOF'
ElementX.xcodeproj/ignored-generated.pbxproj
build/
EOF
    git -C "$repository" add .gitignore ElementX.xcodeproj/project.pbxproj
    git -C "$repository" -c user.name='Release Test' -c user.email=release-test@example.com \
        commit -qm 'Add generated project'
    printf '%s\n' "$repository"
}

CLEAN_REPOSITORY=$(create_repository clean)
(
    cd "$CLEAN_REPOSITORY"
    PATH="$FAKE_BIN:$PATH" XCODEGEN_TEST_MODE=clean bash "$GATE_SCRIPT"
)

for mode in tracked staged untracked ignored-generated; do
    SCENARIO_REPOSITORY=$(create_repository "$mode")
    if (
        cd "$SCENARIO_REPOSITORY"
        PATH="$FAKE_BIN:$PATH" XCODEGEN_TEST_MODE="$mode" bash "$GATE_SCRIPT"
    ); then
        printf 'XcodeGen hygiene accepted %s generated drift.\n' "$mode" >&2
        exit 92
    fi
done

UNRELATED_IGNORED_REPOSITORY=$(create_repository unrelated-ignored)
(
    cd "$UNRELATED_IGNORED_REPOSITORY"
    PATH="$FAKE_BIN:$PATH" XCODEGEN_TEST_MODE=unrelated-ignored bash "$GATE_SCRIPT"
)
