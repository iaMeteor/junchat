#!/bin/bash

set -euo pipefail

xcodegen
git diff --exit-code --
git diff --cached --exit-code --

UNTRACKED_FILES=$(git ls-files --others --exclude-standard)
if [[ -n "$UNTRACKED_FILES" ]]; then
    printf '%s\n' 'XcodeGen produced untracked files:' >&2
    printf '%s\n' "$UNTRACKED_FILES" >&2
    exit 1
fi

GENERATED_PATHS=(
    ElementX.xcodeproj
    AccessibilityTests/SupportingFiles/Info.plist
    ElementX/SupportingFiles/Info.plist
    IntegrationTests/SupportingFiles/Info.plist
    NSE/SupportingFiles/Info.plist
    PreviewTests/SupportingFiles/Info.plist
    ShareExtension/SupportingFiles/Info.plist
    UITests/SupportingFiles/Info.plist
    UnitTests/SupportingFiles/Info.plist
)
IGNORED_GENERATED_FILES=$(git ls-files --others --ignored --exclude-standard -- "${GENERATED_PATHS[@]}")
if [[ -n "$IGNORED_GENERATED_FILES" ]]; then
    printf '%s\n' 'XcodeGen produced ignored files in generated paths:' >&2
    printf '%s\n' "$IGNORED_GENERATED_FILES" >&2
    exit 1
fi
