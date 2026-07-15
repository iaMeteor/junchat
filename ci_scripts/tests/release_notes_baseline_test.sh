#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
COMMON_SCRIPT="$REPOSITORY_ROOT/ci_scripts/ci_common.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/release-notes-baseline-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=ci_common.sh
source "$COMMON_SCRIPT"
unset JUNCHAT_FIRST_RELEASE_BASELINE_COMMIT

resolve_with_first_release_baseline() {
    JUNCHAT_FIRST_RELEASE_BASELINE_COMMIT="$1" \
        resolve_junchat_release_notes_baseline "$2" "$3"
}

assert_version_before() {
    if ! is_junchat_release_version_before "$1" "$2"; then
        printf 'Expected canonical version %s to be before %s.\n' "$1" "$2" >&2
        exit 71
    fi
}

assert_version_not_before() {
    if is_junchat_release_version_before "$1" "$2"; then
        printf 'Expected version %s not to be before %s.\n' "$1" "$2" >&2
        exit 72
    fi
}

create_history() {
    local name="$1"
    SCENARIO_REPOSITORY="$TEST_ROOT/$name"
    git init -q "$SCENARIO_REPOSITORY"
    git -C "$SCENARIO_REPOSITORY" config user.name "Release Test"
    git -C "$SCENARIO_REPOSITORY" config user.email "release-test@example.com"

    printf '%s\n' baseline > "$SCENARIO_REPOSITORY/history.txt"
    git -C "$SCENARIO_REPOSITORY" add history.txt
    git -C "$SCENARIO_REPOSITORY" commit -qm "Baseline"
    BASELINE_COMMIT=$(git -C "$SCENARIO_REPOSITORY" rev-parse HEAD)

    printf '%s\n' feature >> "$SCENARIO_REPOSITORY/history.txt"
    git -C "$SCENARIO_REPOSITORY" commit -qam "Feature change"

    printf '%s\n' archive >> "$SCENARIO_REPOSITORY/history.txt"
    git -C "$SCENARIO_REPOSITORY" commit -qam "Archived change"
    ARCHIVED_COMMIT=$(git -C "$SCENARIO_REPOSITORY" rev-parse HEAD)
    mkdir -p "$SCENARIO_REPOSITORY/signed-app"
}

assert_version_before "1.8.1" "1.8.2"
assert_version_before \
    "18446744073709551615.99999999999999999998.0" \
    "18446744073709551616.0.0"
assert_version_before \
    "18446744073709551616.99999999999999999998.0" \
    "18446744073709551616.99999999999999999999.0"
assert_version_not_before "18446744073709551616.0.0" "1.8.2"
assert_version_not_before "1.8.2" "1.8.2"

for invalid_candidate in \
    "" "01.8.1" "1.08.1" "1.8.01" \
    "1..1" ".1.1" "1.1." \
    "1.8.1-rc.1" "1.8.1+build" "1.8.1.0" \
    "1.\$(touch semver-injection).1"; do
    assert_version_not_before "$invalid_candidate" "1.8.2"
done
for invalid_current in "01.8.2" "1.08.2" "1.8.02" "1..2" "1.8.2-rc.1"; do
    assert_version_not_before "1.8.1" "$invalid_current"
done
test ! -e semver-injection

create_history first-release
if (
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "1.8.2" "$ARCHIVED_COMMIT"
); then
    printf '%s\n' 'A first release without an explicit baseline succeeded.' >&2
    exit 81
fi

(
    cd "$SCENARIO_REPOSITORY"
    resolve_with_first_release_baseline "$BASELINE_COMMIT" "1.8.2" "$ARCHIVED_COMMIT"
    test -z "$JUNCHAT_PREVIOUS_RELEASE_TAG"
    test "$JUNCHAT_RELEASE_NOTES_START_COMMIT" = "$BASELINE_COMMIT"
    CI_APP_STORE_SIGNED_APP_PATH="$SCENARIO_REPOSITORY/signed-app" \
        CI_WORKFLOW=Release \
        generate_what_to_test_notes "$JUNCHAT_RELEASE_NOTES_START_COMMIT" "$ARCHIVED_COMMIT"
    grep -Fq 'Archived change' TestFlight/WhatToTest.en-US.txt
)

if (
    cd "$SCENARIO_REPOSITORY"
    resolve_with_first_release_baseline "$BASELINE_COMMIT" "01.8.2" "$ARCHIVED_COMMIT"
); then
    printf '%s\n' 'A noncanonical current release version accepted a first-release baseline.' >&2
    exit 85
fi

create_history only-current
git -C "$SCENARIO_REPOSITORY" tag release/1.8.2 "$ARCHIVED_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag release/18446744073709551616.0.0 "$BASELINE_COMMIT"
if (
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "1.8.2" "$ARCHIVED_COMMIT"
); then
    printf '%s\n' 'A current or huge future release tag was accepted as the previous baseline.' >&2
    exit 82
fi

create_history noncanonical-tags
git -C "$SCENARIO_REPOSITORY" tag release/01.8.1 "$BASELINE_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag release/1.08.1 "$BASELINE_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag release/1.8.01 "$BASELINE_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag release/1.8.1-rc.1 "$BASELINE_COMMIT"
if (
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "1.8.2" "$ARCHIVED_COMMIT"
); then
    printf '%s\n' 'A noncanonical formal release tag was accepted as the previous baseline.' >&2
    exit 86
fi

create_history huge-current
HUGE_PREVIOUS_VERSION=18446744073709551615.99999999999999999998.0
HUGE_CURRENT_VERSION=18446744073709551616.0.0
HUGE_FUTURE_VERSION=18446744073709551617.0.0
git -C "$SCENARIO_REPOSITORY" tag "release/$HUGE_PREVIOUS_VERSION" "$BASELINE_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag "release/$HUGE_CURRENT_VERSION" "$ARCHIVED_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag "release/$HUGE_FUTURE_VERSION" "$BASELINE_COMMIT"
(
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "$HUGE_CURRENT_VERSION" "$ARCHIVED_COMMIT"
    test "$JUNCHAT_PREVIOUS_RELEASE_TAG" = "release/$HUGE_PREVIOUS_VERSION"
    test "$JUNCHAT_RELEASE_NOTES_START_COMMIT" = "$BASELINE_COMMIT"
)

create_history unrelated-tag
UNRELATED_TREE=$(git -C "$SCENARIO_REPOSITORY" rev-parse "$BASELINE_COMMIT^{tree}")
UNRELATED_COMMIT=$(printf '%s\n' 'Unrelated release' | git -C "$SCENARIO_REPOSITORY" commit-tree "$UNRELATED_TREE")
git -C "$SCENARIO_REPOSITORY" tag release/1.8.1 "$UNRELATED_COMMIT"
if (
    cd "$SCENARIO_REPOSITORY"
    resolve_with_first_release_baseline "$BASELINE_COMMIT" "1.8.2" "$ARCHIVED_COMMIT"
); then
    printf '%s\n' 'A non-ancestor formal release tag was accepted.' >&2
    exit 83
fi

create_history previous-release
git -C "$SCENARIO_REPOSITORY" tag -a release/1.8.1 -m 'Previous release' "$BASELINE_COMMIT"
(
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "1.8.2" "$ARCHIVED_COMMIT"
    test "$JUNCHAT_PREVIOUS_RELEASE_TAG" = 'release/1.8.1'
    test "$JUNCHAT_RELEASE_NOTES_START_COMMIT" = "$BASELINE_COMMIT"
)

git -C "$SCENARIO_REPOSITORY" tag release/1.8.2 "$ARCHIVED_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag release/26.06.0 "$ARCHIVED_COMMIT"
git -C "$SCENARIO_REPOSITORY" tag release/18446744073709551616.0.0 "$BASELINE_COMMIT"
(
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "1.8.2" "$ARCHIVED_COMMIT"
    test "$JUNCHAT_PREVIOUS_RELEASE_TAG" = 'release/1.8.1'
    test "$JUNCHAT_RELEASE_NOTES_START_COMMIT" = "$BASELINE_COMMIT"
    CI_APP_STORE_SIGNED_APP_PATH="$SCENARIO_REPOSITORY/signed-app" \
        CI_WORKFLOW=Release \
        generate_what_to_test_notes "$JUNCHAT_RELEASE_NOTES_START_COMMIT" "$ARCHIVED_COMMIT"
    grep -Fq 'Feature change' TestFlight/WhatToTest.en-US.txt
    grep -Fq 'Archived change' TestFlight/WhatToTest.en-US.txt
)

if (
    cd "$SCENARIO_REPOSITORY"
    CI_APP_STORE_SIGNED_APP_PATH="$SCENARIO_REPOSITORY/signed-app" \
        CI_WORKFLOW=Release \
        generate_what_to_test_notes "$ARCHIVED_COMMIT" "$ARCHIVED_COMMIT"
); then
    printf '%s\n' 'An empty TestFlight notes range succeeded.' >&2
    exit 84
fi
