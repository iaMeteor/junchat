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

create_history only-current
git -C "$SCENARIO_REPOSITORY" tag release/1.8.2 "$ARCHIVED_COMMIT"
if (
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "1.8.2" "$ARCHIVED_COMMIT"
); then
    printf '%s\n' 'A repository with only the current release tag succeeded without a baseline.' >&2
    exit 82
fi

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
(
    cd "$SCENARIO_REPOSITORY"
    resolve_junchat_release_notes_baseline "1.8.2" "$ARCHIVED_COMMIT"
    test "$JUNCHAT_PREVIOUS_RELEASE_TAG" = 'release/1.8.1'
    test "$JUNCHAT_RELEASE_NOTES_START_COMMIT" = "$BASELINE_COMMIT"
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
