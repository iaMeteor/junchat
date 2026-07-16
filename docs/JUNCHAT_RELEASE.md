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
swift run --disable-automatic-resolution -q tools ci validate-junchat-release-preflight
```

Use the repository's existing Xcode build and test schemes for the release
candidate. Do not set `JUNCHAT_SKIP_SWIFTLINT=1` as a normal release path.
The Release Hygiene pull-request workflow watches `project.yml`, `app.yml`, all
`**/SupportingFiles/target.yml` files, variant specs, and generated release
metadata. Its tested XcodeGen gate rejects unstaged or staged tracked changes,
all ordinary untracked files, and ignored untracked drift inside the generated
Xcode project and Info.plist paths. Unrelated ignored build output is excluded.

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
The post-xcodebuild shell entry applies the same official Xcode Cloud archive
identity, then runs the complete local-only release/XcodeGen preflight before
`git fetch`, GitHub release lookup, dSYM upload, or any remote-capable command.
It accepts only the existing `Release` and `Nightly` archive workflows; unknown
or missing workflow identity fails without running a command. The Swift
`release-to-github` gate still independently requires `Release` and repeats the
local preflight as defense in depth.

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
unrelated remote advancement fails closed. Acceptance requires an immediate
final reread of the mutable branch to return the same fully verified preparation
commit. The branch update captures `origin`, its GitHub owner/repository, and the
checked-out symbolic branch during preflight; `CI_BRANCH` must identify that
same branch. Immediately before push, the command rejects changed repository or
checkout identity, then pushes the exact preparation commit SHA to the captured
repository/ref with a lease on the archived SHA. It never selects a destination
by rereading a changed `origin` or a source through mutable `HEAD`. A concurrent
push failure performs the same stable remote validation before treating the
operation as complete.

Draft creation or reuse captures the GitHub release ID, exact body, name, tag,
target commitish, and peeled tag commit. Immediately before the branch push,
the command reads that release again by ID and requires every captured field,
draft state, and peeled tag commit to remain unchanged. Editing, publishing, or
deleting the draft, renaming its tag, or moving either a lightweight or
annotated tag stops the operation before `git push` can run.

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
marketing version and freezes the highest earlier published stable release's
GitHub release ID, `release/*` tag, and remotely peeled commit SHA. The local
tag must exist and peel to that exact frozen SHA, whether lightweight or
annotated; a missing, malformed, or moved tag fails closed. The current release
tag and tags for later versions are excluded, and the selected commit must be a
strict ancestor of the archived commit. A first formal JunChat release with no
earlier tag must set
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
