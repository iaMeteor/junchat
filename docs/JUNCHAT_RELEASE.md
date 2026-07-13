# JunChat iOS Release

## Version Metadata

`project.yml` is the only source for the shipped marketing version and build
number. `MARKETING_VERSION` uses `MAJOR.MINOR.PATCH`; `CURRENT_PROJECT_VERSION`
is a positive integer that must increase for every uploaded build.

Validate a prepared version without changing files:

```sh
swift run -q tools set-junchat-release-version \
  --version-name 1.8.2 \
  --build-number 37 \
  --validate-only
```

Prepare a new version and regenerate the Xcode project:

```sh
swift run -q tools set-junchat-release-version \
  --version-name 1.8.3 \
  --build-number 38
```

The command rejects duplicate or missing fields, semantic-version downgrades,
and non-increasing build numbers. Repeating the exact prepared pair is a safe
no-op. It does not commit, tag, push, upload, or contact a server.

## Verification

Before starting an archive:

```sh
swift test
swiftformat Tools Package.swift --lint
xcodegen
git diff --exit-code -- ElementX.xcodeproj ElementX/SupportingFiles/Info.plist NSE/SupportingFiles/Info.plist ShareExtension/SupportingFiles/Info.plist
```

Use the repository's existing Xcode build and test schemes for the release
candidate. Do not set `JUNCHAT_SKIP_SWIFTLINT=1` as a normal release path.

## Publication

Only the Xcode Cloud `Release` workflow should invoke
`swift run -q tools ci release-to-github`. It derives the GitHub repository from
`origin`, creates a draft that targets the archived commit explicitly, writes
JunChat notes to `JUNCHAT_CHANGES.md`, prepares the next patch and build, and
pushes only the current branch. It never rewrites or rebases an unrelated
branch. The GitHub release remains a draft until a separate explicit publication
approval; review its tag target, notes, and artifacts before publishing it.

Release credentials, Apple signing certificates, provisioning profiles, and
entitlements remain managed by the existing secure Xcode Cloud/signing setup.
Do not copy them into the repository or change signing configuration as part of
a version bump.

## Rollback

Before publication, revert the release-preparation commit and regenerate the
project. After a GitHub or App Store/TestFlight publication, do not reuse its
build number or tag; prepare a higher build and document the corrective release
in `JUNCHAT_CHANGES.md`.
