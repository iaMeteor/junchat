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
