# Local Element Call Candidate Builds

`build-element-call-candidate` performs a one-shot build with a retained Element Call schema-v4 candidate. Its default mode is an unsigned Debug iOS Simulator build. An explicit `--device-udid` adds an ephemeral Apple Development-signed iOS build, validates it, installs it on that registered device, and then removes the staged app. An explicit `--archive-path` creates a Release iphoneos archive, and optional `--export-path` plus `--export-options-plist` exports that archive. None of these modes replaces the checked-in dependency.

## Usage

Run the command from the repository root. Candidate mode requires all three identity options plus a complete local SourcePackages seed; partial candidate input or a seed outside candidate mode is rejected.

```sh
/usr/bin/xcrun swift run --disable-automatic-resolution tools \
    build-element-call-candidate \
    --manifest-path /canonical/absolute/path/to/manifest.json \
    --manifest-sha256 <64-lowercase-hex-digest> \
    --source-commit <40-lowercase-hex-commit> \
    --source-packages-path /canonical/absolute/path/to/SourcePackages
```

To install the same transient candidate on a registered development device, add its hardware UDID:

```sh
/usr/bin/xcrun swift run --disable-automatic-resolution tools \
    build-element-call-candidate \
    --manifest-path /canonical/absolute/path/to/manifest.json \
    --manifest-sha256 <64-lowercase-hex-digest> \
    --source-commit <40-lowercase-hex-commit> \
    --source-packages-path /canonical/absolute/path/to/SourcePackages \
    --device-udid <hardware-udid>
```

To create a local distribution archive from the same candidate, provide a fresh
archive output path outside the repository. Add export arguments only when an IPA
is needed:

```sh
/usr/bin/xcrun swift run --disable-automatic-resolution tools \
    build-element-call-candidate \
    --manifest-path /canonical/absolute/path/to/manifest.json \
    --manifest-sha256 <64-lowercase-hex-digest> \
    --source-commit <40-lowercase-hex-commit> \
    --source-packages-path /canonical/absolute/path/to/SourcePackages \
    --archive-path /canonical/absolute/path/to/Junchat.xcarchive \
    --export-path /canonical/absolute/path/to/export-directory \
    --export-options-plist /canonical/absolute/path/to/ExportOptions.plist
```

Device mode requires matching Apple Development identities and development provisioning profiles for Junchat, NSE, and ShareExtension to already exist locally and include the selected UDID. The fixed build does not pass `-allowProvisioningUpdates` or `-allowProvisioningDeviceRegistration`, so it cannot repair or mutate signing configuration. It uses a generic iOS build destination, verifies all three embedded profiles and bundle identities, verifies the complete code signature, and invokes the fixed `xcrun devicectl device install app` operation only after those checks pass.

With no candidate options, the command only verifies that `project.yml` still uses the public `element-call-swift` package at exact version `0.19.1`, then exits. This is also the dependency used by normal, release, and signing workflows. The SourcePackages seed is required only when all three candidate identity options are present and is rejected otherwise.

## Verification And Isolation

The consumer rejects candidates that are published, use a schema other than `junchat.element-call-candidate/v4`, differ from the expected manifest digest or source commit, omit required build records, contain duplicate JSON keys, or use noncanonical, traversing, or symlinked paths. It reads the retained Android AAR once, verifies its digest and size, independently parses its classic ZIP records, and requires an exact byte-for-byte match beneath `assets/element-call/`. It also re-hashes the retained web and iOS package trees before taking an in-memory snapshot of the iOS package.

The verified snapshot is copied to a uniquely named directory under the canonical system temporary directory. The staging root and package directories use mode `0700`; files use mode `0600`. The original candidate path is never put into an Xcode project or passed to Xcode.

The command reads `project.yml` from its initial repository snapshot, parses it with Yams, and requires the checked-in Element Call dependency to remain the public remote `0.19.1` package. It writes a transient XcodeGen spec that switches this dependency to the staged local package, anchors the local Compound package to its validated absolute repository path, and removes `postGenCommand`. In that transient spec only, it replaces ElementX's pre- and post-build script arrays, including code generation, lint/format, and localization post-processing, with empty arrays and binds compilation- and signing-critical path settings to validated files beneath the read-only repository. The three Info.plists and entitlements files, plus ElementX's bridging header and development assets, use validated absolute paths; the fixed `SRCROOT` anchors remaining included relative settings to that repository. Code signing remains disabled in the default simulator mode; explicit device mode enables only Apple Development signing for the private Debug iphoneos product. The candidate gate therefore proves compilation and extension embedding, but does not exercise those repository-maintenance scripts. It then validates the local Swift package identity and generates a transient project. None of these overrides are written to the checked-in spec or project; normal and release builds retain every original script phase.

The checked-in public `Package.resolved` bytes from the same initial repository snapshot are written only as an offline seed. The supplied SourcePackages workspace must use schema 7 and match every public lock pin exactly. Every checkout is compared file-by-file and mode-by-mode with its locked Git HEAD tree without relying on index cleanliness. A raw byte mismatch is accepted only when the locked blob, expanded through the checkout's tracked Git attributes under the fixed no-global-config environment, exactly reproduces the working file; local `info/attributes`, executable filter configuration, and lazy object fetching remain disabled. Local executable/external or per-worktree Git configuration, active hooks, replacement refs, redirected common metadata, escaping symlinks, and unsupported entry types are rejected. A locked broken checkout symlink is accepted only when its normalized relative destination remains lexically inside that checkout; resolvable links must also remain physically inside it. Untracked entries are rejected except for Xcode's `.swiftpm/xcode` workspace scaffold when both components are real directories and `xcode` is empty; no untracked file, symlink, or additional directory is accepted. Every artifact, prebuilt, and local checkout origin must stay beneath that seed. Cached symlinks use the same normalized relative-destination rule beneath the complete seed, and resolvable targets must remain physically inside it. The complete seed is copied into the private staging root using APFS copy-on-write; its absolute workspace paths and local checkout origins are rebased, and the complete recursively reachable Git alternate-object-store graph is validated, required to contain only real files and directories, and rebased into that private root. Both the staged copy and unchanged source are then revalidated. Xcode receives the same no-replacement/no-global-config/no-lazy-fetch Git environment, explicitly resolves the transient graph from the staged SourcePackages path with remote package updates skipped under the network sandbox, and must produce a refreshed lock that removes exactly the remote Element Call pin, refreshes its origin hash, and leaves every unrelated pin unchanged. The final build uses the same private SourcePackages path, disables automatic resolution, and accepts only versions from that validated lock.

The package identity probe and transient XcodeGen generation each run in their own network-denying sandbox. Both explicit package resolution and the fixed `ElementX` Debug build run through `Tools/Scripts/run_xcodebuild.sh`; simulator mode disables signing, while device mode fixes the SDK to iphoneos, destination to generic iOS, and identity to Apple Development. The wrapper enforces at least 80 GiB free on `/System/Volumes/Data`, a workspace-wide inherited advisory lock, no active `xcodebuild` or `XCBBuildService`, network denial, and read-only rules for the worktree, its worktree Git directory, and the common Git directory. It opens the fixed lock with `O_NOFOLLOW` and verifies the descriptor and pathname identify the same single-link, caller-owned, mode-0600 regular file before locking. A private ready/go handshake prevents the fixed sandbox/Xcode payload from executing before the parent has captured its independent process group. On HUP, INT, TERM, or a normal leader exit with surviving descendants, the wrapper terminates the complete group, escalates to KILL after ten seconds, waits until that group is absent, and only then reaps the leader. The lock file is never unlinked; descriptor 9 is inherited through the real sandbox launcher by descendants, so an uncatchable wrapper exit cannot make the lock available while a descendant that still holds the descriptor is running.

The fixed command-line user default `-IDEPackageSupportDisableManifestSandbox=1` and child-only `XBS_DISABLE_SANDBOXED_BUILDS=YES` environment value disable nested package/build sandboxes because their real profiles cannot be applied beneath the wrapper sandbox. The candidate build also adds Swift's `-disable-sandbox` through inherited Swift flags so compiler macro subprocesses do not attempt another nested sandbox. Those subprocesses still inherit the stricter outer network and repository-write boundary, which remains in force for the entire Xcode process tree. No persistent user preference is written.

The command snapshots `project.yml`, `app.yml`, the checked-in project and lock, Git `HEAD`, and the complete porcelain status before candidate work. It verifies those snapshots after resolution, after build, and again before cleanup so candidate tooling cannot silently persist repository or Git-state changes.

## Trust Boundary

The caller-supplied manifest SHA-256 proves equality with the bytes selected by the caller; it does not authenticate who produced them. Schema-v4 command and tool records are checked for exact semantics, but same-user build inputs and invocation records remain inside the trust base. The retained candidate must therefore come from a trusted local workflow and remain protected from same-user modification until verification snapshots it.

SourcePackages artifact records retain the checksum of each original remote archive, but this local seed retains only the extracted XCFramework directories, so those archive checksums cannot re-authenticate the extracted files. The SwiftSyntax prebuilt record likewise has no independently trusted content digest. Their paths, real entry types, and internal symlink confinement are validated, but their contents remain explicit trusted-local operational inputs. Distribution archives are therefore local release-candidate artifacts that require the manifest digest, source commit, archive path, export options, signing material, and upload decision to be reviewed together. Explicit device mode permits only an ephemeral Apple Development-signed Debug install on the selected registered device for manual acceptance.

This consumer does not extend release gates, publish candidates, request signing updates, or make server changes. Passing the local simulator build or installing the development-device build is evidence that the verified retained package integrates with this checkout; neither is release provenance.

## Cleanup

On success or a handled failure, the command removes its entire `junchat-element-call-ios-*` staging root, including the transient spec, project, package, DerivedData, signed or unsigned app, and the explicitly located result bundle. Device mode completes installation before this cleanup; it does not retain an IPA or app bundle. Xcode's `TMPDIR` is also set to this root for other temporary output. A cleanup failure is reported together with the primary failure and retained staging path instead of being suppressed. The command never deletes the retained source candidate.

An uncatchable termination such as `SIGKILL` can prevent staging and handshake-directory cleanup. The inherited advisory lock remains held by any surviving descendant that retains descriptor 9, so a successor build still fails closed. After confirming that the advisory lock is acquirable and no candidate command or Xcode build is active, the integration owner may remove stale `junchat-element-call-ios-*` and `junchat-xcodebuild-handshake.*` directories from the canonical system temporary directory. Cleanup ownership for the retained cross-platform candidate remains the owner recorded in its manifest.
