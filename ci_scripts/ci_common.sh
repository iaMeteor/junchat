#!/bin/bash

# Return on failures
# Fail when expanding unset variables
# Trace each command before executing it
set -eEu

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

is_junchat_release_version_before() {
    local candidate_version="$1"
    local current_version="$2"
    local version_pattern='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
    local candidate_major candidate_minor candidate_patch
    local current_major current_minor current_patch

    if [[ ! "$candidate_version" =~ $version_pattern ]]; then
        return 1
    fi
    candidate_major=$((10#${BASH_REMATCH[1]}))
    candidate_minor=$((10#${BASH_REMATCH[2]}))
    candidate_patch=$((10#${BASH_REMATCH[3]}))

    if [[ ! "$current_version" =~ $version_pattern ]]; then
        return 1
    fi
    current_major=$((10#${BASH_REMATCH[1]}))
    current_minor=$((10#${BASH_REMATCH[2]}))
    current_patch=$((10#${BASH_REMATCH[3]}))

    if ((candidate_major != current_major)); then
        ((candidate_major < current_major))
    elif ((candidate_minor != current_minor)); then
        ((candidate_minor < current_minor))
    else
        ((candidate_patch < current_patch))
    fi
}

resolve_junchat_release_notes_baseline() {
    local current_version="$1"
    local archived_revision="$2"
    local current_tag="release/$current_version"
    local release_tags candidate_tag candidate_version previous_tag=""
    local archived_commit previous_commit first_release_baseline resolved_baseline

    export JUNCHAT_PREVIOUS_RELEASE_TAG=""
    export JUNCHAT_RELEASE_NOTES_START_COMMIT=""

    if ! archived_commit=$(git rev-parse --verify "$archived_revision^{commit}"); then
        printf '%s\n' "resolve_junchat_release_notes_baseline: Could not resolve archived commit $archived_revision." >&2
        return 1
    fi
    if ! release_tags=$(git tag --list 'release/*' --sort=-version:refname); then
        printf '%s\n' 'resolve_junchat_release_notes_baseline: Could not list formal release tags.' >&2
        return 1
    fi

    while IFS= read -r candidate_tag; do
        [[ -n "$candidate_tag" ]] || continue
        [[ "$candidate_tag" != "$current_tag" ]] || continue
        candidate_version=${candidate_tag#release/}
        if is_junchat_release_version_before "$candidate_version" "$current_version"; then
            previous_tag="$candidate_tag"
            break
        fi
    done <<< "$release_tags"

    if [[ -n "$previous_tag" ]]; then
        if ! previous_commit=$(git rev-parse --verify "$previous_tag^{commit}"); then
            printf '%s\n' "resolve_junchat_release_notes_baseline: Could not peel $previous_tag to a commit." >&2
            return 1
        fi
        if [[ "$previous_commit" = "$archived_commit" ]] ||
           ! git merge-base --is-ancestor "$previous_commit" "$archived_commit"; then
            printf '%s\n' "resolve_junchat_release_notes_baseline: $previous_tag is not a strict ancestor of $archived_commit." >&2
            return 1
        fi

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

validate_what_to_test_notes_range() {
    local notes

    if ! notes=$(what_to_test_notes_for_range "$1" "$2"); then
        return 1
    fi
    [[ -n "$notes" ]]
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

    printf "generate_what_to_test_notes: Generated notes:\n%s\n" "$notes"

    mkdir -p "$testflight_dir_path"
    printf '%s\n' "$notes" > "$testflight_dir_path/$testflight_notes_file_name"
}

fetch_unshallow_repository() {
    # Xcode Cloud shallow clones the repo. Release notes need complete tags and history.
    git fetch --unshallow --quiet
}
