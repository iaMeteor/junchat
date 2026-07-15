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
and non-increasing build numbers. Repeating the exact prepared pair leaves the
version fields unchanged but regenerates the Xcode project so a failed earlier
generation can be retried safely. It does not commit, tag, push, upload, or
contact a server.

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
pushes only the current branch. The command requires a completely clean
repository, including the index and untracked files, before contacting GitHub.
Its preparation commit changes exactly `JUNCHAT_CHANGES.md`, `project.yml`,
and `ElementX.xcodeproj/project.pbxproj`, and records the released version,
build, archived commit, and date in validated commit trailers.

The command enforces that boundary before it reads repository state or can
perform a mutable action. Xcode Cloud must provide the exact official identity
values `CI=TRUE`, `CI_XCODE_CLOUD=TRUE`, `CI_WORKFLOW=Release`, and
`CI_XCODEBUILD_ACTION=archive`, plus a nonempty `CI_WORKFLOW_ID`. Local runs,
other workflows or actions, alternate boolean values, and missing values fail
closed. `GITHUB_TOKEN` is checked only after this environment gate.

If a run fails after draft creation, a clean CI retry lists authenticated
releases and reuses only the same draft, non-prerelease tag and name after
peeling that tag to the archived commit; a published, prerelease, or mismatched
release fails closed. A newly created draft is accepted only after its actual
lightweight or annotated `release/<version>` tag also peels to the archived
commit; the response's `target_commitish` is not sufficient. Xcode Cloud Rebuild starts from
the same archived commit, so the command also checks the current remote branch
before making local changes. It accepts an already-pushed preparation only when
it is the archived commit's sole child, carries the exact validated marker,
modifies exactly the three expected regular-file paths with mode `100644`, and
reproduces the next version and changelog from the archived parent. Any
unrelated remote advancement fails closed. The branch update names the captured
branch explicitly and leases it to the archived SHA, so deletion, rewind, or
replacement fails closed. A concurrent push failure performs the same
validation before treating the operation as complete.

Remote preparation reads are bound to the verified archived and prepared
commits. For each commit, the command verifies the recursive Git tree identity,
requires the three allowlisted paths to be regular `100644` blobs, and obtains
their bytes from the Git Blob API by exact SHA. It rejects truncated or
mismatched trees, blob SHA/size/encoding discrepancies, decoded-length or Git
object-hash mismatches, non-UTF-8 content, and provider errors. This supports
`project.pbxproj` files larger than the Contents API's 1 MiB inline-content
limit. Authenticated reads remain ephemeral, cacheless, and `no-store`.

If HEAD is already the preparation commit, a retry applies the same parent,
version, path, draft, and changelog checks before an idempotent branch push. A
same-workspace retry with partial tracked changes fails closed; retry from a
clean checkout rather than deleting or committing ambiguous state. The command
never rewrites, rebases, or force-pushes an unrelated branch. The GitHub release
remains a draft until a separate explicit publication approval; review its tag
target, notes, and artifacts before publishing it.

Release preparation commits use `git -c user.name="Element CI" -c
user.email="ci@element.io" commit ...`. Release and nightly tooling never write
the caller's global git configuration; nightly tags are lightweight and need no
tagger identity.

Before upload or GitHub orchestration, the Release workflow reads the current
marketing version and freezes the highest earlier stable `release/*` tag and
its peeled commit. The current release tag and tags for later versions are
excluded, and the selected commit must be a strict ancestor of the archived
commit. A first formal JunChat release with no earlier tag must set
`JUNCHAT_FIRST_RELEASE_BASELINE_COMMIT` to an exact lowercase 40-character
commit SHA that is a strict ancestor. Missing or unrelated baselines and empty
note ranges stop the workflow before remote-capable commands run.

TestFlight notes use that frozen commit as the start and the archived commit as
the end of their Git log range, so a fetched current release tag cannot collapse
the range and the later `Prepare next release` metadata commit is not included.
The same preflight enforces App Store Connect's 4,000-character `whatsNew`
contract before dSYM upload, GitHub draft/tag creation, preparation commit, or
push. The limit is counted as Unicode scalar values, matching API `maxLength`
semantics, rather than UTF-8 bytes or extended grapheme clusters. The generated
file has no extra trailing newline, so its exact contents are what passed
validation.

Release credentials, Apple signing certificates, provisioning profiles, and
entitlements remain managed by the existing secure Xcode Cloud/signing setup.
Do not copy them into the repository or change signing configuration as part of
a version bump.

## Rollback

Before publication, revert the release-preparation commit and regenerate the
project. After a GitHub or App Store/TestFlight publication, do not reuse its
build number or tag; prepare a higher build and document the corrective release
in `JUNCHAT_CHANGES.md`.
