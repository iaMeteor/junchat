#!/bin/bash

source ci_common.sh
validate_xcode_cloud_post_build_environment

TEMPORARY_ROOT=${TMPDIR:-/tmp}
RELEASE_ARTIFACT_BINDING_DIRECTORY=$(mktemp -d "${TEMPORARY_ROOT%/}/junchat-release-artifacts.XXXXXX")
chmod 700 "$RELEASE_ARTIFACT_BINDING_DIRECTORY"
RELEASE_ARTIFACT_BINDING_PATH="$RELEASE_ARTIFACT_BINDING_DIRECTORY/binding.json"
RELEASE_ARTIFACT_BINDING_DIGEST_PATH="$RELEASE_ARTIFACT_BINDING_DIRECTORY/binding.sha256"

cleanup_release_artifact_binding() {
    rm -rf -- "$RELEASE_ARTIFACT_BINDING_DIRECTORY"
}
trap cleanup_release_artifact_binding EXIT

# Move to the project root
cd ..

# Complete every local release and generated-file check before remote reads or side effects.
swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight \
    --artifact-binding-path "$RELEASE_ARTIFACT_BINDING_PATH" \
    --artifact-binding-digest-path "$RELEASE_ARTIFACT_BINDING_DIGEST_PATH"
EXPECTED_RELEASE_ARTIFACT_BINDING_DIGEST=$(tr -d '\n' < "$RELEASE_ARTIFACT_BINDING_DIGEST_PATH")
rm "$RELEASE_ARTIFACT_BINDING_DIGEST_PATH"
if [[ ! "$EXPECTED_RELEASE_ARTIFACT_BINDING_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Release artifact preflight returned an invalid binding digest." >&2
    exit 1
fi

revalidate_release_artifact_binding() {
    swift run --disable-automatic-resolution -q tools ci validate-junchat-release-artifact-binding \
        --artifact-binding-path "$RELEASE_ARTIFACT_BINDING_PATH" \
        --expected-artifact-binding-digest "$EXPECTED_RELEASE_ARTIFACT_BINDING_DIGEST"
}

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
revalidate_release_artifact_binding
swift run -q tools ci upload-dsyms \
    --dsym-path "$CI_ARCHIVE_PATH/dSYMs" \
    --artifact-binding-path "$RELEASE_ARTIFACT_BINDING_PATH" \
    --expected-artifact-binding-digest "$EXPECTED_RELEASE_ARTIFACT_BINDING_DIGEST"

if [ "$CI_WORKFLOW" = "Release" ]; then
    revalidate_release_artifact_binding
    swift run -q tools ci release-to-github \
        --artifact-binding-path "$RELEASE_ARTIFACT_BINDING_PATH" \
        --expected-artifact-binding-digest "$EXPECTED_RELEASE_ARTIFACT_BINDING_DIGEST"
elif [ "$CI_WORKFLOW" = "Nightly" ]; then
    revalidate_release_artifact_binding
    swift run -q tools ci tag-nightly \
        --build-number "$CI_BUILD_NUMBER" \
        --artifact-binding-path "$RELEASE_ARTIFACT_BINDING_PATH" \
        --expected-artifact-binding-digest "$EXPECTED_RELEASE_ARTIFACT_BINDING_DIGEST"
fi

if [ "$CI_WORKFLOW" = "Release" ]; then
    generate_what_to_test_notes "$RELEASE_NOTES_START_COMMIT" "$ARCHIVED_COMMIT"
else
    generate_what_to_test_notes "$ARCHIVED_COMMIT"
fi
