#!/bin/bash

# Return on failures
# Fail when expanding unset variables
# Trace each command before executing it
set -eEu

validate_xcode_cloud_post_build_environment() {
    local workflow_id="${CI_WORKFLOW_ID-}"

    if [[ "${CI-}" != TRUE ]]; then
        printf '%s\n' 'validate_xcode_cloud_post_build_environment: CI must be TRUE.' >&2
        return 1
    fi
    if [[ "${CI_XCODE_CLOUD-}" != TRUE ]]; then
        printf '%s\n' 'validate_xcode_cloud_post_build_environment: CI_XCODE_CLOUD must be TRUE.' >&2
        return 1
    fi
    if [[ "${CI_XCODEBUILD_ACTION-}" != archive ]]; then
        printf '%s\n' 'validate_xcode_cloud_post_build_environment: CI_XCODEBUILD_ACTION must be archive.' >&2
        return 1
    fi
    if [[ -z "${workflow_id//[[:space:]]/}" ]]; then
        printf '%s\n' 'validate_xcode_cloud_post_build_environment: CI_WORKFLOW_ID must be nonempty.' >&2
        return 1
    fi
    case "${CI_WORKFLOW-}" in
        Release|Nightly)
            ;;
        *)
            printf '%s\n' 'validate_xcode_cloud_post_build_environment: CI_WORKFLOW must be Release or Nightly.' >&2
            return 1
            ;;
    esac
}

install_xcode_cloud_brew_dependencies () {
    brew update && brew install xcodegen pkl getsentry/tools/sentry-cli
}

setup_github_actions_environment() {
    xcode_select_for_github_actions
    
    unset HOMEBREW_NO_INSTALL_FROM_API
    export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
    
    brew update && brew install xcodegen swiftlint swiftformat git-lfs pkl a7ex/homebrew-formulae/xcresultparser
}

setup_github_actions_translations_environment() {
    xcode_select_for_github_actions
    
    unset HOMEBREW_NO_INSTALL_FROM_API
    export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1

    brew update && brew install swiftgen mint localazy/tools/localazy

    mint install Asana/locheck
}

xcode_select_for_github_actions() {
    # We need to select it globally for other processes like xcresultparser and our custom tools to use the same Xcode version.
    sudo xcode-select -s /Applications/Xcode_26.4.app
}

is_canonical_junchat_release_version() {
    local version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

    [[ "$1" =~ $version_pattern ]]
}

is_canonical_decimal_before() {
    local candidate_component="$1"
    local current_component="$2"
    local LC_ALL=C

    if [[ ${#candidate_component} != "${#current_component}" ]]; then
        [[ ${#candidate_component} -lt ${#current_component} ]]
    else
        [[ "$candidate_component" < "$current_component" ]]
    fi
}

is_junchat_release_version_before() {
    local candidate_version="$1"
    local current_version="$2"
    local candidate_major candidate_minor candidate_patch
    local current_major current_minor current_patch

    if ! is_canonical_junchat_release_version "$candidate_version" ||
       ! is_canonical_junchat_release_version "$current_version"; then
        return 1
    fi

    IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$candidate_version"
    IFS=. read -r current_major current_minor current_patch <<< "$current_version"

    if [[ "$candidate_major" != "$current_major" ]]; then
        is_canonical_decimal_before "$candidate_major" "$current_major"
    elif [[ "$candidate_minor" != "$current_minor" ]]; then
        is_canonical_decimal_before "$candidate_minor" "$current_minor"
    elif [[ "$candidate_patch" != "$current_patch" ]]; then
        is_canonical_decimal_before "$candidate_patch" "$current_patch"
    else
        return 1
    fi
}

resolve_junchat_release_notes_baseline() {
    local current_version="$1"
    local archived_revision="$2"
    local published_release_snapshot="${3-}"
    local current_tag="release/$current_version"
    local snapshot_line candidate_id candidate_tag candidate_commit candidate_version
    local previous_id="" previous_tag="" previous_commit="" previous_version=""
    local archived_commit local_tag_commit first_release_baseline resolved_baseline
    local seen_ids="" seen_tags=""

    export JUNCHAT_PREVIOUS_RELEASE_ID=""
    export JUNCHAT_PREVIOUS_RELEASE_TAG=""
    export JUNCHAT_RELEASE_NOTES_START_COMMIT=""

    if [[ $# -ne 3 ]]; then
        printf '%s\n' 'resolve_junchat_release_notes_baseline: A frozen published-release tag snapshot is required.' >&2
        return 1
    fi
    if ! is_canonical_junchat_release_version "$current_version"; then
        printf '%s\n' "resolve_junchat_release_notes_baseline: $current_version is not a canonical release version." >&2
        return 1
    fi
    if ! archived_commit=$(git rev-parse --verify "$archived_revision^{commit}"); then
        printf '%s\n' "resolve_junchat_release_notes_baseline: Could not resolve archived commit $archived_revision." >&2
        return 1
    fi
    while IFS= read -r snapshot_line; do
        [[ -n "$snapshot_line" ]] || continue
        if [[ "$snapshot_line" != *$'\t'*$'\t'* ]]; then
            printf '%s\n' 'resolve_junchat_release_notes_baseline: Published release snapshot rows must contain ID, tag, and peeled commit SHA.' >&2
            return 1
        fi
        candidate_id=${snapshot_line%%$'\t'*}
        snapshot_line=${snapshot_line#*$'\t'}
        candidate_tag=${snapshot_line%%$'\t'*}
        candidate_commit=${snapshot_line#*$'\t'}
        if [[ "$candidate_commit" = *$'\t'* || ! "$candidate_id" =~ ^[1-9][0-9]*$ ||
              ! "$candidate_commit" =~ ^[0-9a-f]{40}$ ]]; then
            printf '%s\n' 'resolve_junchat_release_notes_baseline: Published release snapshot identity is malformed.' >&2
            return 1
        fi
        candidate_version=${candidate_tag#release/}
        if [[ "$candidate_tag" != "release/$candidate_version" ]] ||
           ! is_canonical_junchat_release_version "$candidate_version"; then
            printf '%s\n' "resolve_junchat_release_notes_baseline: $candidate_tag is not a canonical formal release tag." >&2
            return 1
        fi
        if [[ $'\n'"$seen_ids"$'\n' = *$'\n'"$candidate_id"$'\n'* ||
              $'\n'"$seen_tags"$'\n' = *$'\n'"$candidate_tag"$'\n'* ]]; then
            printf '%s\n' 'resolve_junchat_release_notes_baseline: Published release snapshot contains duplicate identity.' >&2
            return 1
        fi
        seen_ids+="${seen_ids:+$'\n'}$candidate_id"
        seen_tags+="${seen_tags:+$'\n'}$candidate_tag"

        [[ "$candidate_tag" != "$current_tag" ]] || continue
        if is_junchat_release_version_before "$candidate_version" "$current_version" &&
           { [[ -z "$previous_tag" ]] || is_junchat_release_version_before "$previous_version" "$candidate_version"; }; then
            previous_id="$candidate_id"
            previous_tag="$candidate_tag"
            previous_commit="$candidate_commit"
            previous_version="$candidate_version"
        fi
    done <<< "$published_release_snapshot"

    if [[ -n "$previous_tag" ]]; then
        if ! local_tag_commit=$(git rev-parse --verify "$previous_tag^{commit}"); then
            printf '%s\n' "resolve_junchat_release_notes_baseline: Could not peel $previous_tag to a commit." >&2
            return 1
        fi
        if [[ "$local_tag_commit" != "$previous_commit" ]]; then
            printf '%s\n' "resolve_junchat_release_notes_baseline: $previous_tag no longer peels to its frozen published commit." >&2
            return 1
        fi
        if [[ "$previous_commit" = "$archived_commit" ]] ||
           ! git merge-base --is-ancestor "$previous_commit" "$archived_commit"; then
            printf '%s\n' "resolve_junchat_release_notes_baseline: $previous_tag is not a strict ancestor of $archived_commit." >&2
            return 1
        fi

        export JUNCHAT_PREVIOUS_RELEASE_ID="$previous_id"
        export JUNCHAT_PREVIOUS_RELEASE_TAG="$previous_tag"
        export JUNCHAT_RELEASE_NOTES_START_COMMIT="$previous_commit"
        return 0
    fi

    first_release_baseline=${JUNCHAT_FIRST_RELEASE_BASELINE_COMMIT:-}
    if [[ ! "$first_release_baseline" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s\n' 'resolve_junchat_release_notes_baseline: The first formal release requires JUNCHAT_FIRST_RELEASE_BASELINE_COMMIT as a full lowercase 40-character SHA.' >&2
        return 1
    fi
    if ! resolved_baseline=$(git rev-parse --verify "$first_release_baseline^{commit}") ||
       [[ "$resolved_baseline" != "$first_release_baseline" ]]; then
        printf '%s\n' 'resolve_junchat_release_notes_baseline: The configured first-release baseline does not resolve to that exact commit.' >&2
        return 1
    fi
    if [[ "$resolved_baseline" = "$archived_commit" ]] ||
       ! git merge-base --is-ancestor "$resolved_baseline" "$archived_commit"; then
        printf '%s\n' 'resolve_junchat_release_notes_baseline: The configured first-release baseline is not a strict ancestor of the archived commit.' >&2
        return 1
    fi

    export JUNCHAT_RELEASE_NOTES_START_COMMIT="$resolved_baseline"
}

what_to_test_notes_for_range() {
    local range_start_commit="$1"
    local range_end_commit="$2"
    local notes

    if [[ -z "$range_start_commit" || -z "$range_end_commit" || "$range_start_commit" = "$range_end_commit" ]]; then
        printf '%s\n' 'what_to_test_notes_for_range: The release notes range must contain at least one commit.' >&2
        return 1
    fi
    if ! git merge-base --is-ancestor "$range_start_commit" "$range_end_commit"; then
        printf '%s\n' 'what_to_test_notes_for_range: The release notes start is not an ancestor of the archived commit.' >&2
        return 1
    fi
    if ! notes=$(git log --pretty='- %an: %s' "$range_start_commit".."$range_end_commit"); then
        printf '%s\n' 'what_to_test_notes_for_range: Git could not generate TestFlight notes.' >&2
        return 1
    fi
    if [[ -z "${notes//[[:space:]]/}" ]]; then
        printf '%s\n' 'what_to_test_notes_for_range: The release notes range generated no notes.' >&2
        return 1
    fi
    printf '%s\n' "$notes"
}

validate_what_to_test_notes() {
    local notes="$1"
    local scalar_count
    local LC_ALL=C.UTF-8

    if [[ -z "${notes//[[:space:]]/}" ]]; then
        printf '%s\n' 'validate_what_to_test_notes: TestFlight notes must not be empty.' >&2
        return 1
    fi
    if ! printf '%s' "$notes" | iconv -f UTF-8 -t UTF-8 >/dev/null; then
        printf '%s\n' 'validate_what_to_test_notes: TestFlight notes are not valid UTF-8.' >&2
        return 1
    fi

    scalar_count=${#notes}
    if ((scalar_count > 4000)); then
        printf 'validate_what_to_test_notes: TestFlight notes contain %s Unicode scalars; App Store Connect allows at most 4000.\n' "$scalar_count" >&2
        return 1
    fi
}

validate_what_to_test_notes_range() {
    local notes

    if ! notes=$(what_to_test_notes_for_range "$1" "$2"); then
        return 1
    fi
    validate_what_to_test_notes "$notes"
}

generate_what_to_test_notes() {
    local range_start_commit="${1:-}"
    local range_end_commit="${2:-$1}"
    local latest_tag notes
    local testflight_dir_path=TestFlight
    local testflight_notes_file_name=WhatToTest.en-US.txt

    if [[ "$CI_WORKFLOW" = "Nightly" ]]; then
        [[ -d "$CI_APP_STORE_SIGNED_APP_PATH" ]] || return 0
        latest_tag=$(git tag --sort=-creatordate | grep 'nightly' | head -n1)
        if [[ -z "$latest_tag" ]]; then
            echo "generate_what_to_test_notes: Failed fetching previous tag"
            return 0
        fi
        notes=$(git log --pretty='- %an: %s' "$latest_tag".."$range_end_commit")
    elif [[ "$CI_WORKFLOW" != "Release" ]]; then
        return 0
    elif [[ ! -d "$CI_APP_STORE_SIGNED_APP_PATH" ]]; then
        printf '%s\n' 'generate_what_to_test_notes: The signed app path is unavailable.' >&2
        return 1
    elif ! notes=$(what_to_test_notes_for_range "$range_start_commit" "$range_end_commit"); then
        return 1
    fi

    validate_what_to_test_notes "$notes" || return 1

    printf "generate_what_to_test_notes: Generated notes:\n%s\n" "$notes"

    mkdir -p "$testflight_dir_path"
    printf '%s' "$notes" > "$testflight_dir_path/$testflight_notes_file_name"
}

fetch_unshallow_repository() {
    # Xcode Cloud shallow clones the repo. Release notes need complete tags and history.
    git fetch --unshallow --quiet
}
