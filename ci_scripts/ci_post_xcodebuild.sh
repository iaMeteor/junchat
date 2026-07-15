#!/bin/bash

source ci_common.sh
validate_xcode_cloud_post_build_environment

# Move to the project root
cd ..

# Xcode Cloud shallow clones the repo. We need full tags and commit history for release notes.
fetch_unshallow_repository
ARCHIVED_COMMIT=$(git rev-parse --verify HEAD)
RELEASE_NOTES_START_COMMIT=""

if [ "$CI_WORKFLOW" = "Release" ]; then
    CURRENT_RELEASE_VERSION=$(swift run -q tools ci current-release-version)
    REPOSITORY_URL=$(git remote get-url origin)
    PUBLISHED_RELEASE_SNAPSHOT=$(swift run -q tools ci published-junchat-release-tags --repository-url "$REPOSITORY_URL")
    resolve_junchat_release_notes_baseline "$CURRENT_RELEASE_VERSION" "$ARCHIVED_COMMIT" "$PUBLISHED_RELEASE_SNAPSHOT"
    RELEASE_NOTES_START_COMMIT="$JUNCHAT_RELEASE_NOTES_START_COMMIT"
    validate_what_to_test_notes_range "$RELEASE_NOTES_START_COMMIT" "$ARCHIVED_COMMIT"
fi

# Upload dsyms no matter the workflow
# Perform this step before releasing to github in case it fails.
swift run -q tools ci upload-dsyms --dsym-path "$CI_ARCHIVE_PATH/dSYMs"

if [ "$CI_WORKFLOW" = "Release" ]; then
    swift run -q tools ci release-to-github
elif [ "$CI_WORKFLOW" = "Nightly" ]; then
    swift run -q tools ci tag-nightly --build-number "$CI_BUILD_NUMBER"
fi

if [ "$CI_WORKFLOW" = "Release" ]; then
    generate_what_to_test_notes "$RELEASE_NOTES_START_COMMIT" "$ARCHIVED_COMMIT"
else
    generate_what_to_test_notes "$ARCHIVED_COMMIT"
fi
