#!/bin/bash

source ci_common.sh

# Move to the project root
cd ..

# Xcode Cloud shallow clones the repo. We need full tags and commit history for release notes.
fetch_unshallow_repository

# Upload dsyms no matter the workflow
# Perform this step before releasing to github in case it fails.
swift run -q tools ci upload-dsyms --dsym-path "$CI_ARCHIVE_PATH/dSYMs"

if [ "$CI_WORKFLOW" = "Release" ]; then
    swift run -q tools ci release-to-github
elif [ "$CI_WORKFLOW" = "Nightly" ]; then
    swift run -q tools ci tag-nightly --build-number "$CI_BUILD_NUMBER"
fi

generate_what_to_test_notes
